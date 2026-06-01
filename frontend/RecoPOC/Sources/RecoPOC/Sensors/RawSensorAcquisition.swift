import Foundation

#if canImport(OSLog)
import OSLog
#endif

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

public struct RawSensorProviderReadOutcome: Sendable, Equatable {
    public var result: RawSensorProviderResult
    public var reasonCode: String?
    public var detail: String?
    public var steps: [SensorStepTrace]

    public init(
        result: RawSensorProviderResult,
        reasonCode: String? = nil,
        detail: String? = nil,
        steps: [SensorStepTrace] = []
    ) {
        self.result = result
        self.reasonCode = reasonCode
        self.detail = detail
        self.steps = steps
    }
}

public protocol RawSensorTracingProvider: RawSensorReadingProvider {
    func readWithTrace() async -> RawSensorProviderReadOutcome
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
                    ($0.name.rawValue, AcquisitionStatus($0.state.availability, message: $0.state.diagnosticMessage))
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
    public static let acquisitionWindow: TimeInterval = 60

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

        let captures = await withTaskGroup(of: ProviderCapture.self, returning: [ProviderCapture].self) { group in
            for provider in providers {
                group.addTask {
                    await makeCapture(from: provider, deadline: deadline)
                }
            }

            var captures: [ProviderCapture] = []
            for await capture in group {
                captures.append(capture)
            }
            return captures
        }

        let completedAt = await clock.now()
        let frozenAt = min(completedAt, deadline)
        var fieldsByName: [RawSensorName: RawSensorField] = [:]
        var traces: [SensorProviderTrace] = []
        for capture in captures {
            let field = normalize(
                capture.outcome.result,
                for: capture.sensorName,
                freezeTime: frozenAt
            )
            fieldsByName[field.name] = field
            traces.append(makeTrace(from: capture, field: field))
        }

        for sensorName in RawSensorName.allCases where fieldsByName[sensorName] == nil {
            let field = RawSensorField(
                name: sensorName,
                state: .unavailable(.missingSample),
                reading: nil
            )
            fieldsByName[sensorName] = field
            traces.append(
                SensorProviderTrace(
                    sensor: sensorName,
                    startedAt: frozenAt,
                    endedAt: frozenAt,
                    availability: .omitted,
                    reasonCode: "provider_omitted",
                    detail: "No provider returned a reading for this sensor.",
                    valueSummary: [:],
                    steps: []
                )
            )
        }

        let acquisitionTrace = SensorAcquisitionTrace(
            startedAt: startedAt,
            endedAt: frozenAt,
            deadline: deadline,
            providers: traces
        )
        let snapshot = RawSensorSnapshot(
            startedAt: startedAt,
            frozenAt: frozenAt,
            deadline: deadline,
            fields: Array(fieldsByName.values),
            acquisitionTrace: acquisitionTrace
        )
        return snapshot
    }

    private func makeCapture(
        from provider: any RawSensorReadingProvider,
        deadline: Date
    ) async -> ProviderCapture {
        let startedAt = Date()
        let outcome = await scheduler.value(
            until: deadline,
            clock: clock,
            operation: {
                if let tracingProvider = provider as? any RawSensorTracingProvider {
                    return await tracingProvider.readWithTrace()
                }
                let result = await provider.read()
                return RawSensorProviderReadOutcome(result: result)
            },
            fallback: {
                RawSensorProviderReadOutcome(
                    result: .unavailable(.deadlineExceeded),
                    reasonCode: "deadlineExceeded",
                    detail: "Provider exceeded the snapshot deadline."
                )
            }
        )
        return ProviderCapture(
            sensorName: provider.sensorName,
            startedAt: startedAt,
            endedAt: Date(),
            outcome: outcome
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

    private func makeTrace(from capture: ProviderCapture, field: RawSensorField) -> SensorProviderTrace {
        let reasonCode = capture.outcome.reasonCode ?? field.state.diagnosticMessage
        let trace = SensorProviderTrace(
            sensor: capture.sensorName,
            startedAt: capture.startedAt,
            endedAt: capture.endedAt,
            availability: field.state.availability,
            reasonCode: reasonCode,
            detail: capture.outcome.detail,
            valueSummary: Self.valueSummary(for: field),
            steps: capture.outcome.steps
        )
        SensorAcquisitionLogger.log(provider: capture.sensorName, field: field, trace: trace)
        return trace
    }

    private static func valueSummary(for field: RawSensorField) -> [String: String] {
        guard let values = field.reading?.values else { return [:] }
        var summary: [String: String] = [:]
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            switch key {
            case "latitude", "longitude":
                summary[key] = "present"
            default:
                summary[key] = value.sensorTraceSummary
            }
        }
        return summary
    }
}

private struct ProviderCapture: Sendable {
    var sensorName: RawSensorName
    var startedAt: Date
    var endedAt: Date
    var outcome: RawSensorProviderReadOutcome
}

enum SensorAcquisitionLogger {
    static func log(provider: RawSensorName, field: RawSensorField, trace: SensorProviderTrace) {
        #if canImport(OSLog)
        logger.info(
            "sensor provider=\(provider.rawValue, privacy: .public) availability=\(field.state.availability.rawValue, privacy: .public) reason=\(trace.reasonCode ?? "none", privacy: .public) detail=\(trace.detail ?? "none", privacy: .public) duration_ms=\(trace.durationMs, privacy: .public)"
        )
        #else
        _ = (provider, field, trace)
        #endif
    }

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "RecoPOC", category: "SensorAcquisition")
    #endif
}

func sensorTraceStep<T: Sendable>(
    _ name: String,
    operation: @escaping @Sendable () async -> T,
    classify: @escaping @Sendable (T) -> (AcquisitionAvailability, String?, String?)
) async -> (T, SensorStepTrace) {
    let startedAt = Date()
    let value = await operation()
    let endedAt = Date()
    let classification = classify(value)
    let trace = SensorStepTrace(
        name: name,
        startedAt: startedAt,
        endedAt: endedAt,
        availability: classification.0,
        reasonCode: classification.1,
        detail: classification.2
    )
    return (value, trace)
}

private extension JSONValue {
    var sensorTraceSummary: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return "\(value)"
        case .double(let value): return String(format: "%.3f", value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let value): return "array(\(value.count))"
        case .object(let value): return "object(\(value.count))"
        case .null: return "null"
        }
    }
}
