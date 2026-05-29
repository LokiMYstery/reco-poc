import Foundation

public protocol SensorClock: Sendable {
    func now() async -> Date
}

public struct SystemSensorClock: SensorClock {
    public init() {}

    public func now() async -> Date {
        Date()
    }
}

public protocol SensorDeadlineScheduling: Sendable {
    func value<T: Sendable>(
        until deadline: Date,
        clock: SensorClock,
        operation: @escaping @Sendable () async -> T,
        fallback: @escaping @Sendable () -> T
    ) async -> T
}

public struct TaskDeadlineScheduler: SensorDeadlineScheduling {
    public init() {}

    public func value<T: Sendable>(
        until deadline: Date,
        clock: SensorClock,
        operation: @escaping @Sendable () async -> T,
        fallback: @escaping @Sendable () -> T
    ) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                let remaining = deadline.timeIntervalSince(await clock.now())
                if remaining > 0 {
                    let duration = Duration.seconds(remaining)
                    try? await Task.sleep(for: duration)
                }
                return fallback()
            }

            let first = await group.next() ?? fallback()
            group.cancelAll()
            return first
        }
    }
}

public protocol RawSensorReadingProvider: Sendable {
    var sensorName: RawSensorName { get }
    func read() async -> RawSensorProviderResult
}

public enum RawSensorProviderResult: Sendable, Equatable {
    case reading(RawSensorReading)
    case unavailable(UnavailableReason)
    case stale(RawSensorReading?, StaleReason)
}

public struct SystemBaselineRawSensorAcquirer: RawSensorAcquiring {
    private let clock: @Sendable () -> Date
    private let timezone: @Sendable () -> TimeZone
    private let calendar: Calendar

    public init(
        clock: @escaping @Sendable () -> Date = Date.init,
        timezone: @escaping @Sendable () -> TimeZone = { .current },
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.clock = clock
        self.timezone = timezone
        self.calendar = calendar
    }

    public func acquireSnapshot(deadline: TimeInterval = RawSensorFreezer.deadlineSeconds) async -> RawSensorSnapshot {
        let startedAt = clock()
        let frozenAt = clock()
        let deadlineAt = startedAt.addingTimeInterval(deadline)
        let tz = timezone()
        let fields = RawSensorName.allCases.map { sensorName in
            if sensorName == .time {
                return RawSensorField(
                    name: .time,
                    state: .captured,
                    reading: RawSensorReading(
                        observedAt: startedAt,
                        values: [
                            "timestamp": .string(Self.formatTimestamp(startedAt)),
                            "timezone": .string(tz.identifier),
                        ]
                    )
                )
            }

            return RawSensorField(name: sensorName, state: .unavailable(.unsupported), reading: nil)
        }

        return RawSensorSnapshot(
            capturedAt: startedAt,
            timezone: tz.identifier,
            hour: calendar.component(.hour, from: startedAt),
            weekday: Self.mondayBasedWeekday(for: startedAt, calendar: calendar),
            network: "任意",
            bluetooth: "任意",
            placeType: "任意",
            placeTypeAvailable: false,
            placeTypeConfidence: 0,
            placeTypeQuality: "unavailable",
            activityState: "任意",
            activityStateAvailable: false,
            heartRateZone: nil,
            heartRateAvailable: false,
            noiseAvailable: false,
            calendarAvailable: false,
            weather: nil,
            appEvent: "打开推荐页",
            statuses: Dictionary(
                uniqueKeysWithValues: fields.map {
                    ($0.name.rawValue, AcquisitionStatus($0.state.availability))
                }
            ),
            startedAt: startedAt,
            frozenAt: frozenAt,
            deadline: deadlineAt,
            fields: fields
        )
    }

    private static func mondayBasedWeekday(for date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }
}

public struct NativeCapableRawSensorAcquirer: RawSensorAcquiring {
    private let providers: [any RawSensorReadingProvider]
    private let clock: SensorClock
    private let scheduler: any SensorDeadlineScheduling

    public init(
        providers: [any RawSensorReadingProvider] = NativeSensorProviderCatalog().makeProviders(),
        clock: SensorClock = SystemSensorClock(),
        scheduler: any SensorDeadlineScheduling = TaskDeadlineScheduler()
    ) {
        self.providers = providers
        self.clock = clock
        self.scheduler = scheduler
    }

    public func acquireSnapshot(deadline: TimeInterval = RawSensorFreezer.deadlineSeconds) async -> RawSensorSnapshot {
        await RawSensorSnapshotFreezer(
            providers: providers,
            clock: clock,
            scheduler: scheduler,
            acquisitionWindow: deadline
        ).freeze()
    }
}

public struct RawSensorSnapshotFreezer: Sendable {
    public static let acquisitionWindow: TimeInterval = 15

    private let providers: [any RawSensorReadingProvider]
    private let clock: SensorClock
    private let scheduler: any SensorDeadlineScheduling
    private let acquisitionWindow: TimeInterval

    public init(
        providers: [any RawSensorReadingProvider],
        clock: SensorClock = SystemSensorClock(),
        scheduler: any SensorDeadlineScheduling = TaskDeadlineScheduler(),
        acquisitionWindow: TimeInterval = RawSensorSnapshotFreezer.acquisitionWindow
    ) {
        self.providers = providers
        self.clock = clock
        self.scheduler = scheduler
        self.acquisitionWindow = acquisitionWindow
    }

    public func freeze() async -> RawSensorSnapshot {
        let startedAt = await clock.now()
        let deadline = startedAt.addingTimeInterval(acquisitionWindow)

        let collectedFields = await withTaskGroup(of: RawSensorField.self, returning: [RawSensorField].self) { group in
            for provider in providers {
                group.addTask {
                    await makeField(from: provider, deadline: deadline)
                }
            }

            var collected: [RawSensorField] = []
            for await field in group {
                collected.append(field)
            }
            return collected
        }

        var fieldsByName: [RawSensorName: RawSensorField] = [:]
        for field in collectedFields {
            fieldsByName[field.name] = field
        }

        for sensorName in RawSensorName.allCases where fieldsByName[sensorName] == nil {
            fieldsByName[sensorName] = RawSensorField(
                name: sensorName,
                state: .unavailable(.missingSample),
                reading: nil
            )
        }

        let frozenAt = max(await clock.now(), deadline)
        return RawSensorSnapshot(
            startedAt: startedAt,
            frozenAt: frozenAt,
            deadline: deadline,
            fields: Array(fieldsByName.values)
        )
    }

    private func makeField(
        from provider: any RawSensorReadingProvider,
        deadline: Date
    ) async -> RawSensorField {
        await scheduler.value(
            until: deadline,
            clock: clock,
            operation: {
                let result = await provider.read()
                return normalize(result, for: provider.sensorName, freezeTime: deadline)
            },
            fallback: {
                RawSensorField(
                    name: provider.sensorName,
                    state: .unavailable(.deadlineExceeded),
                    reading: nil
                )
            }
        )
    }

    private func normalize(
        _ result: RawSensorProviderResult,
        for sensorName: RawSensorName,
        freezeTime: Date
    ) -> RawSensorField {
        switch result {
        case let .reading(reading):
            if reading.isStale(at: freezeTime) {
                return RawSensorField(
                    name: sensorName,
                    state: .stale(.exceededFreshnessWindow),
                    reading: reading
                )
            }

            return RawSensorField(
                name: sensorName,
                state: .captured,
                reading: reading
            )

        case let .unavailable(reason):
            return RawSensorField(
                name: sensorName,
                state: .unavailable(reason),
                reading: nil
            )

        case let .stale(reading, reason):
            return RawSensorField(
                name: sensorName,
                state: .stale(reason),
                reading: reading
            )
        }
    }
}
