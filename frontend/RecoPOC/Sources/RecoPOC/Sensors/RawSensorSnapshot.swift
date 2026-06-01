import Foundation

public enum AcquisitionAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case stale
    case omitted
}

public struct AcquisitionStatus: Codable, Equatable, Sendable {
    public var availability: AcquisitionAvailability
    public var message: String?

    public init(_ availability: AcquisitionAvailability, message: String? = nil) {
        self.availability = availability
        self.message = message
    }
}

public struct SensorStepTrace: Codable, Equatable, Sendable {
    public var name: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationMs: Int
    public var availability: AcquisitionAvailability
    public var reasonCode: String?
    public var detail: String?

    public init(
        name: String,
        startedAt: Date,
        endedAt: Date,
        availability: AcquisitionAvailability,
        reasonCode: String? = nil,
        detail: String? = nil
    ) {
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = Self.durationMs(from: startedAt, to: endedAt)
        self.availability = availability
        self.reasonCode = reasonCode
        self.detail = detail
    }

    private static func durationMs(from startedAt: Date, to endedAt: Date) -> Int {
        Int(max(0, endedAt.timeIntervalSince(startedAt) * 1_000))
    }
}

public struct SensorProviderTrace: Codable, Equatable, Sendable {
    public var sensor: RawSensorName
    public var startedAt: Date
    public var endedAt: Date
    public var durationMs: Int
    public var availability: AcquisitionAvailability
    public var reasonCode: String?
    public var detail: String?
    public var valueSummary: [String: String]
    public var steps: [SensorStepTrace]

    public init(
        sensor: RawSensorName,
        startedAt: Date,
        endedAt: Date,
        availability: AcquisitionAvailability,
        reasonCode: String? = nil,
        detail: String? = nil,
        valueSummary: [String: String] = [:],
        steps: [SensorStepTrace] = []
    ) {
        self.sensor = sensor
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = Self.durationMs(from: startedAt, to: endedAt)
        self.availability = availability
        self.reasonCode = reasonCode
        self.detail = detail
        self.valueSummary = valueSummary
        self.steps = steps
    }

    public var diagnosticMessage: String {
        if let reasonCode, let detail, !detail.isEmpty {
            return "\(reasonCode): \(detail)"
        }
        if let reasonCode { return reasonCode }
        if let detail, !detail.isEmpty { return detail }
        return availability == .available ? "captured" : availability.rawValue
    }

    private static func durationMs(from startedAt: Date, to endedAt: Date) -> Int {
        Int(max(0, endedAt.timeIntervalSince(startedAt) * 1_000))
    }
}

public struct SensorAcquisitionTrace: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var deadline: Date
    public var durationMs: Int
    public var providers: [SensorProviderTrace]

    public init(
        startedAt: Date,
        endedAt: Date,
        deadline: Date,
        providers: [SensorProviderTrace]
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.deadline = deadline
        self.durationMs = Int(max(0, endedAt.timeIntervalSince(startedAt) * 1_000))
        self.providers = providers.sorted { $0.sensor.rawValue < $1.sensor.rawValue }
    }
}

public enum RawSensorName: String, Codable, CaseIterable, Hashable, Sendable {
    case time
    case location
    case battery
    case connectivity
    case heading
    case activity
    case motion
    case health
    case microphone
    case calendar
    case weather
}

public enum UnavailableReason: String, Codable, Equatable, Sendable {
    case sensorDisabled
    case deadlineExceeded
    case missingSample
    case permissionDenied
    case unsupported
}

public enum StaleReason: String, Codable, Equatable, Sendable {
    case exceededFreshnessWindow
    case providerMarkedStale
}

public enum RawSensorFieldState: Codable, Equatable, Sendable {
    case captured
    case unavailable(UnavailableReason)
    case stale(StaleReason)
}

public struct RawSensorReading: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var freshnessWindow: TimeInterval?
    public var values: [String: JSONValue]

    public init(observedAt: Date, freshnessWindow: TimeInterval? = nil, values: [String: JSONValue]) {
        self.observedAt = observedAt
        self.freshnessWindow = freshnessWindow
        self.values = values
    }

    public func isStale(at freezeTime: Date) -> Bool {
        guard let freshnessWindow else { return false }
        return freezeTime.timeIntervalSince(observedAt) > freshnessWindow
    }
}

public struct RawSensorField: Codable, Equatable, Sendable {
    public var name: RawSensorName
    public var state: RawSensorFieldState
    public var reading: RawSensorReading?

    public init(name: RawSensorName, state: RawSensorFieldState, reading: RawSensorReading? = nil) {
        self.name = name
        self.state = state
        self.reading = reading
    }
}

public struct RawSensorSnapshot: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var frozenAt: Date
    public var deadline: Date
    public var fields: [RawSensorField]

    public var capturedAt: Date
    public var timezone: String
    public var hour: Int
    public var weekday: Int
    public var network: String
    public var bluetooth: String
    public var placeType: String
    public var placeTypeAvailable: Bool
    public var placeTypeConfidence: Double
    public var placeTypeQuality: String
    public var latitude: Double?
    public var longitude: Double?
    public var locationAccuracyM: Double?
    public var activityState: String
    public var activityStateAvailable: Bool
    public var heartRateZone: String?
    public var heartRateAvailable: Bool
    public var stepsLast10Min: Int?
    public var recentWorkoutMinutes24h: Int?
    public var sleepQuality: String?
    public var noiseClass: String?
    public var noiseAvailable: Bool
    public var calendarKeyword: String?
    public var calendarAvailable: Bool
    public var weather: String?
    public var appEvent: String
    public var statuses: [String: AcquisitionStatus]
    public var acquisitionTrace: SensorAcquisitionTrace?

    public init(
        capturedAt: Date,
        timezone: String,
        hour: Int,
        weekday: Int,
        network: String,
        bluetooth: String,
        placeType: String,
        placeTypeAvailable: Bool,
        placeTypeConfidence: Double,
        placeTypeQuality: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationAccuracyM: Double? = nil,
        activityState: String,
        activityStateAvailable: Bool,
        heartRateZone: String? = nil,
        heartRateAvailable: Bool,
        stepsLast10Min: Int? = nil,
        recentWorkoutMinutes24h: Int? = nil,
        sleepQuality: String? = nil,
        noiseClass: String? = nil,
        noiseAvailable: Bool = false,
        calendarKeyword: String? = nil,
        calendarAvailable: Bool = false,
        weather: String? = nil,
        appEvent: String = "打开推荐页",
        statuses: [String: AcquisitionStatus] = [:],
        acquisitionTrace: SensorAcquisitionTrace? = nil,
        startedAt: Date? = nil,
        frozenAt: Date? = nil,
        deadline: Date? = nil,
        fields: [RawSensorField] = []
    ) {
        self.capturedAt = capturedAt
        self.timezone = timezone
        self.hour = hour
        self.weekday = weekday
        self.network = network
        self.bluetooth = bluetooth
        self.placeType = placeType
        self.placeTypeAvailable = placeTypeAvailable
        self.placeTypeConfidence = placeTypeConfidence
        self.placeTypeQuality = placeTypeQuality
        self.latitude = latitude
        self.longitude = longitude
        self.locationAccuracyM = locationAccuracyM
        self.activityState = activityState
        self.activityStateAvailable = activityStateAvailable
        self.heartRateZone = heartRateZone
        self.heartRateAvailable = heartRateAvailable
        self.stepsLast10Min = stepsLast10Min
        self.recentWorkoutMinutes24h = recentWorkoutMinutes24h
        self.sleepQuality = sleepQuality
        self.noiseClass = noiseClass
        self.noiseAvailable = noiseAvailable
        self.calendarKeyword = calendarKeyword
        self.calendarAvailable = calendarAvailable
        self.weather = weather
        self.appEvent = appEvent
        self.statuses = statuses
        self.acquisitionTrace = acquisitionTrace
        self.startedAt = startedAt ?? capturedAt
        self.frozenAt = frozenAt ?? capturedAt
        self.deadline = deadline ?? (startedAt ?? capturedAt).addingTimeInterval(RawSensorFreezer.deadlineSeconds)
        self.fields = fields.sorted { $0.name.rawValue < $1.name.rawValue }
    }

    public init(
        startedAt: Date,
        frozenAt: Date,
        deadline: Date,
        fields: [RawSensorField],
        acquisitionTrace: SensorAcquisitionTrace? = nil
    ) {
        let sortedFields = fields.sorted { $0.name.rawValue < $1.name.rawValue }
        let fieldMap = Dictionary(uniqueKeysWithValues: sortedFields.map { ($0.name, $0) })
        let calendar = Calendar(identifier: .gregorian)
        let tracesBySensor = Dictionary(
            uniqueKeysWithValues: (acquisitionTrace?.providers ?? []).map { ($0.sensor, $0) }
        )

        let network = Self.stringValue(for: .connectivity, key: "network", in: fieldMap) ?? "任意"
        let bluetooth = Self.stringValue(for: .connectivity, key: "bluetooth", in: fieldMap) ?? "任意"
        let placeType = Self.stringValue(for: .location, key: "place_type", in: fieldMap) ?? "任意"
        let placeTypeConfidence = Self.doubleValue(for: .location, key: "place_type_confidence", in: fieldMap) ?? 0
        let placeTypeQuality = Self.stringValue(for: .location, key: "place_type_quality", in: fieldMap) ?? Self.defaultQuality(for: fieldMap[.location]?.state)
        let poiLookupAvailable = Self.intValue(for: .location, key: "poi_lookup_available", in: fieldMap)
        let latitude = Self.doubleValue(for: .location, key: "latitude", in: fieldMap) ?? Self.doubleValue(for: .location, key: "lat", in: fieldMap)
        let longitude = Self.doubleValue(for: .location, key: "longitude", in: fieldMap) ?? Self.doubleValue(for: .location, key: "lon", in: fieldMap)
        let locationAccuracyM = Self.doubleValue(for: .location, key: "location_accuracy_m", in: fieldMap)
        let activityState = Self.stringValue(for: .activitySensor, key: "activity_state", in: fieldMap) ?? Self.stringValue(for: .motion, key: "activity_state", in: fieldMap) ?? "任意"
        let heartRateZone = Self.stringValue(for: .battery, key: "heart_rate_zone", in: fieldMap) ?? Self.stringValue(for: .health, key: "heart_rate_zone", in: fieldMap)
        let stepsLast10Min = Self.intValue(for: .battery, key: "steps_last_10min", in: fieldMap) ?? Self.intValue(for: .health, key: "steps_last_10min", in: fieldMap)
        let recentWorkoutMinutes24h = Self.intValue(for: .battery, key: "recent_workout_minutes_24h", in: fieldMap) ?? Self.intValue(for: .health, key: "recent_workout_minutes_24h", in: fieldMap)
        let sleepQuality = Self.stringValue(for: .battery, key: "sleep_quality", in: fieldMap) ?? Self.stringValue(for: .health, key: "sleep_quality", in: fieldMap)
        let noiseClass = Self.stringValue(for: .heading, key: "noise_class", in: fieldMap) ?? Self.stringValue(for: .microphone, key: "noise_class", in: fieldMap)
        let calendarKeyword = Self.stringValue(for: .heading, key: "calendar_keyword", in: fieldMap) ?? Self.stringValue(for: .calendar, key: "calendar_keyword", in: fieldMap)
        let weather = Self.stringValue(for: .weather, key: "weather", in: fieldMap)
        let statuses = Dictionary(
            uniqueKeysWithValues: sortedFields.map {
                (
                    $0.name.rawValue,
                    AcquisitionStatus(
                        $0.state.availability,
                        message: tracesBySensor[$0.name]?.diagnosticMessage ?? $0.state.diagnosticMessage
                    )
                )
            }
        )

        self.init(
            capturedAt: frozenAt,
            timezone: TimeZone.current.identifier,
            hour: calendar.component(.hour, from: frozenAt),
            weekday: max(calendar.component(.weekday, from: frozenAt) - 2, 0),
            network: network,
            bluetooth: bluetooth,
            placeType: placeType,
            placeTypeAvailable: Self.isCaptured(fieldMap[.location]) && placeType != "任意" && (poiLookupAvailable.map { $0 > 0 } ?? true),
            placeTypeConfidence: placeTypeConfidence,
            placeTypeQuality: placeTypeQuality,
            latitude: latitude,
            longitude: longitude,
            locationAccuracyM: locationAccuracyM,
            activityState: activityState,
            activityStateAvailable: Self.isCaptured(fieldMap[.activitySensor]) || Self.isCaptured(fieldMap[.motion]),
            heartRateZone: heartRateZone,
            heartRateAvailable: heartRateZone != nil && (Self.isCaptured(fieldMap[.battery]) || Self.isCaptured(fieldMap[.health])),
            stepsLast10Min: stepsLast10Min,
            recentWorkoutMinutes24h: recentWorkoutMinutes24h,
            sleepQuality: sleepQuality,
            noiseClass: noiseClass,
            noiseAvailable: noiseClass != nil && (Self.isCaptured(fieldMap[.heading]) || Self.isCaptured(fieldMap[.microphone])),
            calendarKeyword: calendarKeyword,
            calendarAvailable: calendarKeyword != nil && (Self.isCaptured(fieldMap[.heading]) || Self.isCaptured(fieldMap[.calendar])),
            weather: weather,
            statuses: statuses,
            acquisitionTrace: acquisitionTrace,
            startedAt: startedAt,
            frozenAt: frozenAt,
            deadline: deadline,
            fields: sortedFields
        )
    }

    public subscript(_ name: RawSensorName) -> RawSensorField? {
        fields.first { $0.name == name }
    }

    public static let sampleFullPermission = RawSensorSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_779_986_400),
        timezone: "Asia/Shanghai",
        hour: 10,
        weekday: 2,
        network: "wifi",
        bluetooth: "耳机",
        placeType: "写字楼",
        placeTypeAvailable: true,
        placeTypeConfidence: 0.78,
        placeTypeQuality: "exact_or_good_mapping",
        latitude: 31.2304,
        longitude: 121.4737,
        locationAccuracyM: 35,
        activityState: "静止",
        activityStateAvailable: true,
        heartRateZone: "静息",
        heartRateAvailable: true,
        stepsLast10Min: 250,
        recentWorkoutMinutes24h: 0,
        sleepQuality: "一般",
        noiseClass: "普通",
        noiseAvailable: true,
        calendarKeyword: "会议",
        calendarAvailable: true,
        statuses: ["snapshot": AcquisitionStatus(.available)]
    )

    private static func stringValue(for sensor: RawSensorName, key: String, in fields: [RawSensorName: RawSensorField]) -> String? {
        fields[sensor]?.reading?.values[key]?.stringValue
    }

    private static func doubleValue(for sensor: RawSensorName, key: String, in fields: [RawSensorName: RawSensorField]) -> Double? {
        switch fields[sensor]?.reading?.values[key] {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    private static func intValue(for sensor: RawSensorName, key: String, in fields: [RawSensorName: RawSensorField]) -> Int? {
        switch fields[sensor]?.reading?.values[key] {
        case .int(let value): return value
        default: return nil
        }
    }

    private static func defaultQuality(for state: RawSensorFieldState?) -> String {
        switch state {
        case .captured:
            return "exact_or_good_mapping"
        case .stale:
            return "stale"
        case .unavailable, .none:
            return "unavailable"
        }
    }

    private static func isCaptured(_ field: RawSensorField?) -> Bool {
        field?.state == .captured
    }
}

extension RawSensorFieldState {
    var availability: AcquisitionAvailability {
        switch self {
        case .captured: return .available
        case .unavailable: return .unavailable
        case .stale: return .stale
        }
    }

    var diagnosticMessage: String? {
        switch self {
        case .captured:
            return "captured"
        case .unavailable(let reason):
            return reason.rawValue
        case .stale(let reason):
            return reason.rawValue
        }
    }
}

private extension RawSensorName {
    static var activitySensor: RawSensorName { .activity }
}

public protocol RawSensorAcquiring: Sendable {
    func acquireSnapshot(deadline: TimeInterval) async -> RawSensorSnapshot
}

public struct FakeRawSensorAcquirer: RawSensorAcquiring {
    public var result: Result<RawSensorSnapshot, Never>

    public init(result: Result<RawSensorSnapshot, Never>) {
        self.result = result
    }

    public func acquireSnapshot(deadline: TimeInterval = RawSensorFreezer.deadlineSeconds) async -> RawSensorSnapshot {
        _ = deadline
        switch result {
        case let .success(snapshot):
            return snapshot
        }
    }
}

public struct RawSensorFreezer: Sendable {
    public static let deadlineSeconds: TimeInterval = 60

    public init() {}

    public func freeze(startedAt: Date, completed: RawSensorSnapshot?, now: Date) -> RawSensorSnapshot {
        if let completed { return completed }
        let frozenAt = minDate(now, startedAt.addingTimeInterval(Self.deadlineSeconds))
        let unavailableFields = RawSensorName.allCases.map {
            RawSensorField(name: $0, state: .unavailable(.deadlineExceeded))
        }
        return RawSensorSnapshot(
            startedAt: startedAt,
            frozenAt: frozenAt,
            deadline: startedAt.addingTimeInterval(Self.deadlineSeconds),
            fields: unavailableFields
        )
    }

    private func minDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs <= rhs ? lhs : rhs
    }
}
