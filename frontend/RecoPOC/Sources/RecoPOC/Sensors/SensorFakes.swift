import Foundation

public struct FixedSensorClock: SensorClock {
    public var value: Date

    public init(now: Date) {
        self.value = now
    }

    public func now() async -> Date {
        value
    }
}

public actor SequenceSensorClock: SensorClock {
    private var moments: [Date]
    private var fallback: Date

    public init(moments: [Date], fallback: Date? = nil) {
        precondition(!moments.isEmpty, "SequenceSensorClock requires at least one moment")
        self.moments = moments
        self.fallback = fallback ?? moments[moments.count - 1]
    }

    public func now() async -> Date {
        if moments.isEmpty {
            return fallback
        }

        let value = moments.removeFirst()
        fallback = value
        return value
    }
}

public struct FakeRawSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName
    private let resultFactory: @Sendable () async -> RawSensorProviderResult

    public init(
        sensorName: RawSensorName,
        result: RawSensorProviderResult
    ) {
        self.sensorName = sensorName
        self.resultFactory = { result }
    }

    public init(
        sensorName: RawSensorName,
        resultFactory: @escaping @Sendable () async -> RawSensorProviderResult
    ) {
        self.sensorName = sensorName
        self.resultFactory = resultFactory
    }

    public func read() async -> RawSensorProviderResult {
        await resultFactory()
    }
}

public struct ImmediateDeadlineScheduler: SensorDeadlineScheduling {
    public init() {}

    public func value<T: Sendable>(
        until deadline: Date,
        clock: SensorClock,
        operation: @escaping @Sendable () async -> T,
        fallback: @escaping @Sendable () -> T
    ) async -> T {
        _ = deadline
        _ = clock
        _ = fallback
        return await operation()
    }
}

public struct ControlledDeadlineScheduler: SensorDeadlineScheduling {
    public enum Mode: Sendable {
        case runOperation
        case useFallback
    }

    private let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    public func value<T: Sendable>(
        until deadline: Date,
        clock: SensorClock,
        operation: @escaping @Sendable () async -> T,
        fallback: @escaping @Sendable () -> T
    ) async -> T {
        _ = deadline
        _ = clock

        switch mode {
        case .runOperation:
            return await operation()
        case .useFallback:
            return fallback()
        }
    }
}
