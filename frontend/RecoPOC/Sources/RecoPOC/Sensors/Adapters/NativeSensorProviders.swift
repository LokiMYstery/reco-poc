import Foundation

#if canImport(Network)
import Network
#endif

#if canImport(CoreLocation)
import CoreLocation
#endif

#if os(iOS) && canImport(CoreMotion)
import CoreMotion
#endif

#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFAudio)
import AVFAudio
#endif

#if os(iOS) && canImport(WeatherKit)
import WeatherKit
#endif

public enum AmapInputCoordinateSystem: String, Codable, Equatable, Sendable {
    case gps
    case autonavi
}

public struct AmapPOIConfiguration: Codable, Equatable, Sendable {
    public var apiKey: String
    public var enabled: Bool
    public var inputCoordinateSystem: AmapInputCoordinateSystem
    public var radiusM: Double

    public init(
        apiKey: String = "",
        enabled: Bool = false,
        inputCoordinateSystem: AmapInputCoordinateSystem = .gps,
        radiusM: Double = 500
    ) {
        self.apiKey = apiKey
        self.enabled = enabled
        self.inputCoordinateSystem = inputCoordinateSystem
        self.radiusM = radiusM
    }

    public static let disabled = AmapPOIConfiguration()

    var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasUsableAPIKey: Bool {
        !trimmedAPIKey.isEmpty
    }
}

public struct NativeSensorProviderCatalog {
    private let amapConfiguration: AmapPOIConfiguration
    private let amapClient: any AmapPOIClient

    public init(amapConfiguration: AmapPOIConfiguration = .disabled) {
        self.amapConfiguration = amapConfiguration
        self.amapClient = LiveAmapPOIClient()
    }

    init(
        amapConfiguration: AmapPOIConfiguration = .disabled,
        amapClient: any AmapPOIClient
    ) {
        self.amapConfiguration = amapConfiguration
        self.amapClient = amapClient
    }

    public func makeProviders() -> [any RawSensorReadingProvider] {
        #if canImport(CoreLocation)
        let sharedLocationReader = SharedLocationReader()
        let locationProvider = SystemLocationSnapshotProvider(
            locationReader: sharedLocationReader,
            amapConfiguration: amapConfiguration,
            amapClient: amapClient
        )
        #if os(iOS) && canImport(WeatherKit)
        let weatherProvider = WeatherSensorProvider(locationReader: sharedLocationReader)
        #else
        let weatherProvider = WeatherSensorProvider()
        #endif
        #else
        let locationProvider = LocationSensorProvider()
        let weatherProvider = WeatherSensorProvider()
        #endif
        #if os(iOS) && canImport(CoreMotion)
        let motionActivityProvider = SharedMotionActivitySnapshotProvider()
        let activityProvider = ActivitySensorProvider(provider: motionActivityProvider)
        let motionProvider = MotionSensorProvider(provider: motionActivityProvider)
        #else
        let activityProvider = ActivitySensorProvider()
        let motionProvider = MotionSensorProvider()
        #endif

        let providers: [any RawSensorReadingProvider] = [
            TimeSensorProvider(),
            LocationSensorProvider(provider: locationProvider),
            BatterySensorProvider(),
            ConnectivitySensorProvider(),
            HeadingSensorProvider(),
            activityProvider,
            motionProvider,
            HealthSensorProvider(),
            MicrophoneSensorProvider(),
            CalendarSensorProvider(),
            weatherProvider
        ]
        return providers
    }
}

struct NativeSensorFailure: Error, Equatable, Sendable {
    var reason: UnavailableReason
    var reasonCode: String
    var detail: String?
}

private func nativeNSErrorDiagnostics(prefix: String, error: Error) -> (reasonCode: String, detail: String) {
    let nsError = error as NSError
    let reasonCode = "\(prefix)_error:\(nativeReasonComponent(nsError.domain)):\(nsError.code)"
    var detailParts = [
        "type=\(String(describing: type(of: error)))",
        "domain=\(nsError.domain)",
        "code=\(nsError.code)",
        "message=\(error.localizedDescription)"
    ]

    for key in nsError.userInfo.keys.sorted(by: { "\($0)" < "\($1)" }) {
        guard key != NSLocalizedDescriptionKey else { continue }
        let value = nsError.userInfo[key]!
        if let underlying = value as? NSError {
            detailParts.append("userInfo.\(key)=NSError(domain:\(underlying.domain),code:\(underlying.code),message:\(underlying.localizedDescription))")
        } else {
            detailParts.append("userInfo.\(key)=\(nativeDiagnosticValue(value))")
        }
    }

    return (reasonCode, detailParts.joined(separator: ";"))
}

private func nativeReasonComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    return String(
        value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
    )
}

private func nativeDiagnosticValue(_ value: Any) -> String {
    let raw = String(describing: value)
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: ";", with: ",")
    if raw.count <= 240 { return raw }
    return "\(raw.prefix(240))…"
}

#if canImport(CoreLocation)
private enum NativeLocationConfig {
    static let oneShotTimeout: TimeInterval = 55
    static let desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters
}
#endif

public struct TimeSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .time
    private let now: @Sendable () -> Date
    private let timezone: @Sendable () -> TimeZone

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        timezone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.now = now
        self.timezone = timezone
    }

    public func read() async -> RawSensorProviderResult {
        let observedAt = now()
        return .reading(
            RawSensorReading(
                observedAt: observedAt,
                values: [
                    "timestamp": .string(Self.formatTimestamp(observedAt)),
                    "timezone": .string(timezone().identifier)
                ]
            )
        )
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }
}

public struct LocationSensorProvider: RawSensorReadingProvider, RawSensorTracingProvider {
    public let sensorName: RawSensorName = .location
    private let provider: any LocationSnapshotProviding

    public init(provider: any LocationSnapshotProviding = SystemLocationSnapshotProvider()) {
        self.provider = provider
    }

    public func read() async -> RawSensorProviderResult {
        await provider.readLocationSnapshot()
    }

    public func readWithTrace() async -> RawSensorProviderReadOutcome {
        if let tracingProvider = provider as? any LocationSnapshotTracingProviding {
            return await tracingProvider.readLocationSnapshotWithTrace()
        }
        return RawSensorProviderReadOutcome(result: await provider.readLocationSnapshot())
    }
}

public protocol LocationSnapshotProviding: Sendable {
    func readLocationSnapshot() async -> RawSensorProviderResult
}

public protocol LocationSnapshotTracingProviding: LocationSnapshotProviding {
    func readLocationSnapshotWithTrace() async -> RawSensorProviderReadOutcome
}

public struct SystemLocationSnapshotProvider: LocationSnapshotProviding, LocationSnapshotTracingProviding {
    #if canImport(CoreLocation)
    private let locationReader: any LocationReading
    private let amapConfiguration: AmapPOIConfiguration
    private let amapClient: any AmapPOIClient

    public init() {
        self.locationReader = SharedLocationReader()
        self.amapConfiguration = .disabled
        self.amapClient = LiveAmapPOIClient()
    }

    init(
        locationReader: any LocationReading = SharedLocationReader(),
        amapConfiguration: AmapPOIConfiguration = .disabled,
        amapClient: any AmapPOIClient = LiveAmapPOIClient()
    ) {
        self.locationReader = locationReader
        self.amapConfiguration = amapConfiguration
        self.amapClient = amapClient
    }
    #else
    public init() {}
    #endif

    public func readLocationSnapshot() async -> RawSensorProviderResult {
        await readLocationSnapshotWithTrace().result
    }

    public func readLocationSnapshotWithTrace() async -> RawSensorProviderReadOutcome {
        #if canImport(CoreLocation)
        let (locationReport, locationStep) = await sensorTraceStep(
            "cllocation.request",
            operation: { await locationReader.requestLocation(timeout: NativeLocationConfig.oneShotTimeout) },
            classify: { report in
                switch report.outcome {
                case .success(let location):
                    return (
                        .available,
                        nil,
                        [
                            "accuracy_m=\(Int(max(0, location.horizontalAccuracy.rounded())))",
                            "speed_quality=\(location.speedQuality)"
                        ].joined(separator: ";")
                    )
                case .failure(let failure):
                    return (.unavailable, failure.reasonCode, failure.detail)
                }
            }
        )
        var steps = [locationStep]
        steps.append(contentsOf: locationReport.steps)

        switch locationReport.outcome {
        case .success(let location):
            let (place, placeSteps) = await NativePlaceTypeMapper.derivePlaceWithTrace(
                for: location,
                configuration: amapConfiguration,
                client: amapClient
            )
            steps.append(contentsOf: placeSteps)
            var locationValues: [String: JSONValue] = [
                "latitude": .double(location.latitude),
                "longitude": .double(location.longitude),
                "location_accuracy_m": .double(max(0, location.horizontalAccuracy)),
                "place_type": .string(place.placeType),
                "place_type_confidence": .double(place.confidence),
                "place_type_quality": .string(place.quality),
                "place_source": .string(place.source),
                "poi_lookup_available": .int(place.poiLookupAvailable ? 1 : 0),
                "speed_quality": .string(location.speedQuality),
            ]
            if let speedMPS = location.speedMPS {
                locationValues["speed_mps"] = .double(speedMPS)
            }
            if let speedKmh = location.speedKmh {
                locationValues["speed_kmh"] = .double(speedKmh)
            }
            if !place.candidates.isEmpty {
                locationValues["place_candidates"] = .array(place.candidates.map(\.jsonValue))
            }
            return RawSensorProviderReadOutcome(
                result: .reading(
                    RawSensorReading(
                        observedAt: location.timestamp,
                        freshnessWindow: 60,
                        values: locationValues
                    )
                ),
                detail: "place_quality=\(place.quality);place_source=\(place.source);poi_lookup_available=\(place.poiLookupAvailable ? 1 : 0)",
                steps: steps
            )
        case .failure(let failure):
            return RawSensorProviderReadOutcome(
                result: .unavailable(failure.reason),
                reasonCode: failure.reasonCode,
                detail: failure.detail,
                steps: steps
            )
        }
        #else
        return RawSensorProviderReadOutcome(
            result: .unavailable(.unsupported),
            reasonCode: "corelocation_unsupported",
            detail: "CoreLocation is not available in this build."
        )
        #endif
    }

    #if canImport(CoreLocation)
    fileprivate static func authorizationStatus() -> CLAuthorizationStatus {
        CLLocationManager().authorizationStatus
    }

    fileprivate static func authorizationFailure(for status: CLAuthorizationStatus) -> NativeSensorFailure? {
        switch status {
        case .denied, .restricted:
            return NativeSensorFailure(
                reason: .permissionDenied,
                reasonCode: "location_permission_denied",
                detail: "CoreLocation authorization is denied or restricted."
            )
        case .notDetermined:
            return NativeSensorFailure(
                reason: .missingSample,
                reasonCode: "location_permission_not_determined",
                detail: "CoreLocation authorization has not been granted yet."
            )
        default:
            return NativeLocationAuthorization.isAuthorized(status)
                ? nil
                : NativeSensorFailure(
                    reason: .unsupported,
                    reasonCode: "location_authorization_unsupported",
                    detail: "CoreLocation authorization status is unsupported: \(authorizationLabel(for: status))."
                )
        }
    }

    fileprivate static func authorizationLabel(for status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorized_always"
        case .authorizedWhenInUse: return "authorized_when_in_use"
        @unknown default: return "unknown"
        }
    }
    #endif
}

public struct BatterySensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .battery
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}

public struct ConnectivitySensorProvider: RawSensorReadingProvider, RawSensorTracingProvider {
    public let sensorName: RawSensorName = .connectivity
    private let pathProvider: any NetworkPathSnapshotProviding
    private let routeProvider: any AudioRouteProviding

    public init(
        pathProvider: any NetworkPathSnapshotProviding = SystemNetworkPathSnapshotProvider(),
        routeProvider: any AudioRouteProviding = SystemAudioRouteProvider()
    ) {
        self.pathProvider = pathProvider
        self.routeProvider = routeProvider
    }

    public func read() async -> RawSensorProviderResult {
        await readWithTrace().result
    }

    public func readWithTrace() async -> RawSensorProviderReadOutcome {
        let observedAt = Date()
        async let routeCapture = sensorTraceStep(
            "audio_route.current",
            operation: { await routeProvider.currentRouteLabel() },
            classify: { route in
                (.available, nil, "route=\(route)")
            }
        )
        async let pathCapture = sensorTraceStep(
            "network.path_monitor",
            operation: { await pathProvider.currentPathSnapshot() },
            classify: { snapshot in
                guard let snapshot else {
                    return (
                        .unavailable,
                        "network_monitor_timeout",
                        "NWPathMonitor did not produce a path snapshot before fallback."
                    )
                }
                return (.available, nil, "status=\(snapshot.statusLabel);network=\(snapshot.networkLabel)")
            }
        )

        let (route, routeStep) = await routeCapture
        let (pathSnapshot, pathStep) = await pathCapture
        var values: [String: JSONValue] = ["bluetooth": .string(route)]

        if let pathSnapshot {
            values["network"] = .string(pathSnapshot.networkLabel)
            values["network_path_status"] = .string(pathSnapshot.statusLabel)
            if let isExpensive = pathSnapshot.isExpensive {
                values["network_is_expensive"] = .bool(isExpensive)
            }
            if let isConstrained = pathSnapshot.isConstrained {
                values["network_is_constrained"] = .bool(isConstrained)
            }
        } else {
            values["network"] = .string("任意")
        }

        return RawSensorProviderReadOutcome(
            result: .reading(RawSensorReading(observedAt: observedAt, freshnessWindow: 30, values: values)),
            steps: [routeStep, pathStep]
        )
    }
}

public protocol NetworkPathSnapshotProviding: Sendable {
    func currentPathSnapshot() async -> NetworkPathSnapshot?
}

public struct NetworkPathSnapshot: Sendable {
    public let networkLabel: String
    public let statusLabel: String
    public let isExpensive: Bool?
    public let isConstrained: Bool?

    public init(networkLabel: String, statusLabel: String, isExpensive: Bool?, isConstrained: Bool?) {
        self.networkLabel = networkLabel
        self.statusLabel = statusLabel
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

public struct SystemNetworkPathSnapshotProvider: NetworkPathSnapshotProviding {
    public init() {}

    public func currentPathSnapshot() async -> NetworkPathSnapshot? {
        #if canImport(Network)
        if #available(iOS 12.0, macOS 10.14, *) {
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "RecoPOC.NetworkPathMonitor")
            return await withCheckedContinuation { continuation in
                let box = SensorSingleResumeBox(continuation) {
                    monitor.cancel()
                }
                monitor.pathUpdateHandler = { path in
                    box.resume(returning: Self.snapshot(from: path))
                }
                monitor.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 2) {
                    box.resume(returning: Self.snapshot(from: monitor.currentPath))
                }
            }
        }
        #endif
        return nil
    }

    #if canImport(Network)
    @available(iOS 12.0, macOS 10.14, *)
    private static func snapshot(from path: NWPath) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            networkLabel: Self.networkLabel(for: path),
            statusLabel: Self.statusLabel(for: path.status),
            isExpensive: path.isExpensive,
            isConstrained: Self.isConstrained(path)
        )
    }

    @available(iOS 12.0, macOS 10.14, *)
    private static func networkLabel(for path: NWPath) -> String {
        guard path.status == .satisfied else { return "离线" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return path.isExpensive ? "蜂窝数据（弱）" : "蜂窝数据" }
        if path.usesInterfaceType(.wiredEthernet) { return "以太网" }
        if path.usesInterfaceType(.loopback) { return "本地回环" }
        if path.usesInterfaceType(.other) { return "其他网络" }
        return "任意"
    }

    @available(iOS 12.0, macOS 10.14, *)
    private static func statusLabel(for status: NWPath.Status) -> String {
        switch status {
        case .satisfied: return "satisfied"
        case .requiresConnection: return "requires_connection"
        case .unsatisfied: return "unsatisfied"
        @unknown default: return "unknown"
        }
    }

    @available(iOS 12.0, macOS 10.14, *)
    private static func isConstrained(_ path: NWPath) -> Bool? {
        if #available(iOS 13.0, macOS 10.15, *) {
            return path.isConstrained
        }
        return nil
    }
    #endif
}

public protocol AudioRouteProviding: Sendable {
    func currentRouteLabel() async -> String
}

public struct SystemAudioRouteProvider: AudioRouteProviding {
    public init() {}

    public func currentRouteLabel() async -> String {
        #if os(iOS) && canImport(AVFoundation)
        if #available(iOS 17.0, *) {
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            guard let port = outputs.first else { return "任意" }
            return Self.mapAudioPort(port.portType)
        }
        #endif
        return "任意"
    }

    #if os(iOS) && canImport(AVFoundation)
    @available(iOS 17.0, *)
    private static func mapAudioPort(_ portType: AVAudioSession.Port) -> String {
        switch portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return "蓝牙音频"
        case .headphones, .headsetMic:
            return "耳机"
        case .builtInSpeaker:
            return "扬声器"
        case .builtInReceiver:
            return "听筒"
        case .airPlay:
            return "AirPlay"
        case .carAudio:
            return "车载音频"
        default:
            return "其他音频"
        }
    }
    #endif
}

public struct HeadingSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .heading
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}

public struct ActivitySensorProvider: RawSensorReadingProvider, RawSensorTracingProvider {
    public let sensorName: RawSensorName = .activity
    #if os(iOS) && canImport(CoreMotion)
    private let provider: any MotionActivitySnapshotProviding

    public init() {
        self.provider = SharedMotionActivitySnapshotProvider()
    }

    fileprivate init(provider: any MotionActivitySnapshotProviding) {
        self.provider = provider
    }
    #else
    public init() {}
    #endif

    public func read() async -> RawSensorProviderResult {
        await readWithTrace().result
    }

    public func readWithTrace() async -> RawSensorProviderReadOutcome {
        #if os(iOS) && canImport(CoreMotion)
        return await provider.readMotionActivitySnapshot()
        #else
        return RawSensorProviderReadOutcome(
            result: .unavailable(.unsupported),
            reasonCode: "motion_unsupported",
            detail: "CoreMotion activity is only available in the iOS host."
        )
        #endif
    }
}

public struct MotionSensorProvider: RawSensorReadingProvider, RawSensorTracingProvider {
    public let sensorName: RawSensorName = .motion
    #if os(iOS) && canImport(CoreMotion)
    private let provider: any MotionActivitySnapshotProviding

    public init() {
        self.provider = SharedMotionActivitySnapshotProvider()
    }

    fileprivate init(provider: any MotionActivitySnapshotProviding) {
        self.provider = provider
    }
    #else
    public init() {}
    #endif

    public func read() async -> RawSensorProviderResult {
        await readWithTrace().result
    }

    public func readWithTrace() async -> RawSensorProviderReadOutcome {
        #if os(iOS) && canImport(CoreMotion)
        return await provider.readMotionActivitySnapshot()
        #else
        return RawSensorProviderReadOutcome(
            result: .unavailable(.unsupported),
            reasonCode: "motion_unsupported",
            detail: "CoreMotion activity is only available in the iOS host."
        )
        #endif
    }
}

public struct HealthSensorProvider: RawSensorReadingProvider, RawSensorTracingProvider {
    public let sensorName: RawSensorName = .health
    public init() {}
    public func read() async -> RawSensorProviderResult {
        await readWithTrace().result
    }

    public func readWithTrace() async -> RawSensorProviderReadOutcome {
        #if os(iOS) && canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            return RawSensorProviderReadOutcome(
                result: .unavailable(.sensorDisabled),
                reasonCode: "health_data_unavailable",
                detail: "HealthKit data is not available on this device."
            )
        }

        let reader = HealthKitSnapshotReader()
        let (values, steps) = await reader.readHealthValuesWithTrace()
        guard !values.isEmpty else {
            return RawSensorProviderReadOutcome(
                result: .unavailable(.missingSample),
                reasonCode: "health_no_samples",
                detail: "HealthKit returned no usable heart rate, steps, workout, or sleep samples.",
                steps: steps
            )
        }
        return RawSensorProviderReadOutcome(
            result: .reading(RawSensorReading(observedAt: Date(), freshnessWindow: 300, values: values)),
            steps: steps
        )
        #else
        return RawSensorProviderReadOutcome(
            result: .unavailable(.unsupported),
            reasonCode: "healthkit_unsupported",
            detail: "HealthKit is not available in this build."
        )
        #endif
    }
}

public struct MicrophoneSensorProvider: RawSensorReadingProvider, RawSensorTracingProvider {
    public let sensorName: RawSensorName = .microphone
    #if os(iOS) && canImport(AVFAudio)
    private let provider: any MicrophoneNoiseSnapshotProviding

    public init() {
        self.provider = SystemMicrophoneNoiseSnapshotProvider()
    }

    fileprivate init(provider: any MicrophoneNoiseSnapshotProviding) {
        self.provider = provider
    }
    #else
    public init() {}
    #endif

    public func read() async -> RawSensorProviderResult {
        await readWithTrace().result
    }

    public func readWithTrace() async -> RawSensorProviderReadOutcome {
        #if os(iOS) && canImport(AVFAudio)
        return await provider.readNoiseSnapshot()
        #else
        return RawSensorProviderReadOutcome(
            result: .unavailable(.unsupported),
            reasonCode: "microphone_unsupported",
            detail: "Microphone noise classification is only available in the iOS host."
        )
        #endif
    }
}

public struct CalendarSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .calendar
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}


public struct WeatherSensorProvider: RawSensorReadingProvider, RawSensorTracingProvider {
    public let sensorName: RawSensorName = .weather
    #if os(iOS) && canImport(WeatherKit) && canImport(CoreLocation)
    private let locationReader: any LocationReading

    public init() {
        self.locationReader = SharedLocationReader()
    }

    fileprivate init(locationReader: any LocationReading = SharedLocationReader()) {
        self.locationReader = locationReader
    }
    #else
    public init() {}
    #endif

    public func read() async -> RawSensorProviderResult {
        await readWithTrace().result
    }

    public func readWithTrace() async -> RawSensorProviderReadOutcome {
        #if os(iOS) && canImport(WeatherKit) && canImport(CoreLocation)
        let (locationReport, locationStep) = await sensorTraceStep(
            "weather.location_request",
            operation: { await locationReader.requestLocation(timeout: NativeLocationConfig.oneShotTimeout) },
            classify: { report in
                switch report.outcome {
                case .success(let location):
                    return (.available, nil, "accuracy_m=\(Int(max(0, location.horizontalAccuracy.rounded())))")
                case .failure(let failure):
                    return (.unavailable, failure.reasonCode, failure.detail)
                }
            }
        )
        var steps = [locationStep]
        steps.append(contentsOf: locationReport.steps)
        guard case .success(let location) = locationReport.outcome else {
            if case .failure(let failure) = locationReport.outcome {
                return RawSensorProviderReadOutcome(
                    result: .unavailable(failure.reason),
                    reasonCode: failure.reasonCode,
                    detail: "WeatherKit location prerequisite failed: \(failure.detail ?? failure.reasonCode)",
                    steps: steps
                )
            }
            return RawSensorProviderReadOutcome(
                result: .unavailable(.missingSample),
                reasonCode: "weather_location_missing",
                detail: "WeatherKit could not get a location.",
                steps: steps
            )
        }

        let weatherStartedAt = Date()
        do {
            let weather = try await WeatherService.shared.weather(for: location.clLocation)
            let condition = NativeWeatherMapper.label(for: weather.currentWeather.condition)
            var values: [String: JSONValue] = [
                "weather": .string(condition),
                "raw_weather_condition": .string(String(describing: weather.currentWeather.condition)),
                "weather_temperature_c": .double(weather.currentWeather.temperature.converted(to: .celsius).value),
            ]
            values["weather_fetched_at"] = .string(Self.formatTimestamp(Date()))
            steps.append(
                SensorStepTrace(
                    name: "weatherkit.fetch",
                    startedAt: weatherStartedAt,
                    endedAt: Date(),
                    availability: .available,
                    detail: "condition=\(condition)"
                )
            )
            return RawSensorProviderReadOutcome(
                result: .reading(RawSensorReading(observedAt: Date(), freshnessWindow: 900, values: values)),
                steps: steps
            )
        } catch {
            let diagnostics = Self.weatherErrorDiagnostics(for: error)
            steps.append(
                SensorStepTrace(
                    name: "weatherkit.fetch",
                    startedAt: weatherStartedAt,
                    endedAt: Date(),
                    availability: .unavailable,
                    reasonCode: diagnostics.reasonCode,
                    detail: diagnostics.detail
                )
            )
            return RawSensorProviderReadOutcome(
                result: .unavailable(.missingSample),
                reasonCode: diagnostics.reasonCode,
                detail: diagnostics.detail,
                steps: steps
            )
        }
        #else
        return RawSensorProviderReadOutcome(
            result: .unavailable(.unsupported),
            reasonCode: "weatherkit_unsupported",
            detail: "WeatherKit or CoreLocation is not available in this build."
        )
        #endif
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }

    private static func weatherErrorDiagnostics(for error: Error) -> (reasonCode: String, detail: String) {
        nativeNSErrorDiagnostics(prefix: "weatherkit", error: error)
    }
}

#if canImport(CoreLocation)
struct LocationSample: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var timestamp: Date
    var speedMPS: Double?
    var speedKmh: Double?
    var speedQuality: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: max(0, horizontalAccuracy),
            verticalAccuracy: -1,
            course: -1,
            speed: speedMPS ?? -1,
            timestamp: timestamp
        )
    }

    init(_ location: CLLocation, now: Date = Date()) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.timestamp = location.timestamp
        let speedDecision = Self.validSpeed(from: location, now: now)
        self.speedMPS = speedDecision.speedMPS
        self.speedKmh = speedDecision.speedMPS.map { $0 * 3.6 }
        self.speedQuality = speedDecision.quality
    }

    private static func validSpeed(from location: CLLocation, now: Date) -> (speedMPS: Double?, quality: String) {
        guard location.speed >= 0 else {
            return (nil, "invalid")
        }
        let sampleAge = now.timeIntervalSince(location.timestamp)
        guard sampleAge >= 0, sampleAge <= 30 else {
            return (nil, "stale")
        }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else {
            return (nil, "low_accuracy")
        }
        return (location.speed, "valid")
    }
}

enum LocationReadOutcome: Equatable, Sendable {
    case success(LocationSample)
    case failure(NativeSensorFailure)
}

struct LocationReadReport: Equatable, Sendable {
    var outcome: LocationReadOutcome
    var steps: [SensorStepTrace]

    init(outcome: LocationReadOutcome, steps: [SensorStepTrace] = []) {
        self.outcome = outcome
        self.steps = steps
    }
}

protocol LocationReading: Sendable {
    func requestLocation(timeout: TimeInterval) async -> LocationReadReport
}

actor SharedLocationReader: LocationReading {
    private var inFlight: Task<LocationReadReport, Never>?
    private let operation: @Sendable (TimeInterval) async -> LocationReadReport

    init(operation: @escaping @Sendable (TimeInterval) async -> LocationReadReport = { timeout in
        await OneShotLocationReader.shared.requestLocation(timeout: timeout)
    }) {
        self.operation = operation
    }

    func requestLocation(timeout: TimeInterval = NativeLocationConfig.oneShotTimeout) async -> LocationReadReport {
        if let inFlight {
            return await inFlight.value
        }

        let task = Task {
            await operation(timeout)
        }
        inFlight = task
        let report = await task.value
        inFlight = nil
        return report
    }
}

private struct LocationDelegateUpdate: Sendable {
    var rawCount: Int
    var validSamples: [LocationSample]

    init(locations: [CLLocation]) {
        self.rawCount = locations.count
        self.validSamples = locations
            .map { LocationSample($0) }
            .filter { $0.horizontalAccuracy >= 0 }
            .sorted { $0.horizontalAccuracy < $1.horizontalAccuracy }
    }
}

private struct LocationDelegateFailure: Sendable {
    var failure: NativeSensorFailure
    var detail: String

    init(error: Error) {
        let nsError = error as NSError
        if let clError = error as? CLError, clError.code == .denied {
            self.failure = NativeSensorFailure(
                reason: .permissionDenied,
                reasonCode: "cllocation_error_denied",
                detail: "domain=\(nsError.domain) code=\(nsError.code) message=\(error.localizedDescription)"
            )
        } else {
            let code = (error as? CLError).map { "\($0.code.rawValue)" } ?? String(describing: type(of: error))
            self.failure = NativeSensorFailure(
                reason: .missingSample,
                reasonCode: "cllocation_error:\(code)",
                detail: "domain=\(nsError.domain) code=\(nsError.code) message=\(error.localizedDescription)"
            )
        }
        self.detail = failure.detail ?? error.localizedDescription
    }
}

@MainActor
private final class OneShotLocationReader: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = OneShotLocationReader()

    private let manager: CLLocationManager
    private var pendingRequest: PendingLocationRequest?

    override init() {
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = NativeLocationConfig.desiredAccuracy
    }

    func requestLocation(timeout: TimeInterval = NativeLocationConfig.oneShotTimeout) async -> LocationReadReport {
        await withCheckedContinuation { continuation in
            let box = SensorSingleResumeBox(continuation)
            start(box, timeout: timeout)
        }
    }

    private func start(_ box: SensorSingleResumeBox<LocationReadReport>, timeout: TimeInterval) {
        replacePendingRequestIfNeeded()

        let startedAt = Date()
        var steps = [
            SensorStepTrace(
                name: "corelocation.manager_init",
                startedAt: startedAt,
                endedAt: startedAt,
                availability: .available,
                detail: "main_thread=\(Thread.isMainThread);desired_accuracy_m=\(Int(NativeLocationConfig.desiredAccuracy))"
            )
        ]

        let authorizationStartedAt = Date()
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        if let failure = SystemLocationSnapshotProvider.authorizationFailure(for: status) {
            steps.append(
                SensorStepTrace(
                    name: "corelocation.authorization",
                    startedAt: authorizationStartedAt,
                    endedAt: Date(),
                    availability: .unavailable,
                    reasonCode: failure.reasonCode,
                    detail: "status=\(SystemLocationSnapshotProvider.authorizationLabel(for: status));accuracy=\(Self.accuracyLabel(for: accuracy));\(failure.detail ?? failure.reasonCode)"
                )
            )
            box.resume(returning: LocationReadReport(outcome: .failure(failure), steps: steps))
            return
        }

        steps.append(
            SensorStepTrace(
                name: "corelocation.authorization",
                startedAt: authorizationStartedAt,
                endedAt: Date(),
                availability: .available,
                detail: "status=\(SystemLocationSnapshotProvider.authorizationLabel(for: status));accuracy=\(Self.accuracyLabel(for: accuracy))"
            )
        )

        let requestStartedAt = Date()
        steps.append(
            SensorStepTrace(
                name: "corelocation.request_location",
                startedAt: requestStartedAt,
                endedAt: Date(),
                availability: .available,
                detail: "timeout_s=\(Int(timeout));desired_accuracy_m=\(Int(NativeLocationConfig.desiredAccuracy))"
            )
        )
        pendingRequest = PendingLocationRequest(box: box, requestStartedAt: requestStartedAt, steps: steps)
        manager.requestLocation()

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak box] in
            guard let self, let box else { return }
            Task { @MainActor in
                self.handleTimeout(box: box, timeout: timeout)
            }
        }
    }

    private func replacePendingRequestIfNeeded() {
        guard let pendingRequest else { return }
        let step = SensorStepTrace(
            name: "corelocation.request_replaced",
            startedAt: Date(),
            endedAt: Date(),
            availability: .unavailable,
            reasonCode: "cllocation_replaced_pending_request",
            detail: "A newer CoreLocation request replaced the pending request."
        )
        let failure = NativeSensorFailure(
            reason: .missingSample,
            reasonCode: "cllocation_replaced_pending_request",
            detail: "A newer CoreLocation request replaced the pending request."
        )
        pendingRequest.box.resume(
            returning: LocationReadReport(outcome: .failure(failure), steps: pendingRequest.steps + [step])
        )
        self.pendingRequest = nil
        manager.stopUpdatingLocation()
    }

    private func handleTimeout(box: SensorSingleResumeBox<LocationReadReport>, timeout: TimeInterval) {
        guard let pendingRequest, pendingRequest.box === box else { return }
        let failure = NativeSensorFailure(
            reason: .deadlineExceeded,
            reasonCode: "cllocation_timeout",
            detail: "CLLocationManager did not return didUpdateLocations or didFailWithError within \(Int(timeout))s."
        )
        let step = SensorStepTrace(
            name: "corelocation.timeout",
            startedAt: pendingRequest.requestStartedAt,
            endedAt: Date(),
            availability: .unavailable,
            reasonCode: failure.reasonCode,
            detail: failure.detail
        )
        complete(.failure(failure), step: step, box: box)
    }

    private func handleUpdate(_ update: LocationDelegateUpdate) {
        guard let pendingRequest else { return }
        guard let location = update.validSamples.first else {
            let failure = NativeSensorFailure(
                reason: .missingSample,
                reasonCode: "cllocation_no_valid_location",
                detail: "CLLocationManager returned \(update.rawCount) locations but none had nonnegative horizontalAccuracy."
            )
            let step = SensorStepTrace(
                name: "corelocation.did_update_locations",
                startedAt: pendingRequest.requestStartedAt,
                endedAt: Date(),
                availability: .unavailable,
                reasonCode: failure.reasonCode,
                detail: failure.detail
            )
            complete(.failure(failure), step: step)
            return
        }

        let ageSeconds = max(0, Int(Date().timeIntervalSince(location.timestamp).rounded()))
        let step = SensorStepTrace(
            name: "corelocation.did_update_locations",
            startedAt: pendingRequest.requestStartedAt,
            endedAt: Date(),
            availability: .available,
            detail: "locations=\(update.rawCount);valid=\(update.validSamples.count);accuracy_m=\(Int(max(0, location.horizontalAccuracy).rounded()));timestamp_age_s=\(ageSeconds)"
        )
        complete(.success(location), step: step)
    }

    private func handleFailure(_ failure: LocationDelegateFailure) {
        guard let pendingRequest else { return }
        let step = SensorStepTrace(
            name: "corelocation.did_fail_with_error",
            startedAt: pendingRequest.requestStartedAt,
            endedAt: Date(),
            availability: .unavailable,
            reasonCode: failure.failure.reasonCode,
            detail: failure.detail
        )
        complete(.failure(failure.failure), step: step)
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        guard let pendingRequest, let failure = SystemLocationSnapshotProvider.authorizationFailure(for: status) else { return }
        let step = SensorStepTrace(
            name: "corelocation.authorization_change",
            startedAt: pendingRequest.requestStartedAt,
            endedAt: Date(),
            availability: .unavailable,
            reasonCode: failure.reasonCode,
            detail: "status=\(SystemLocationSnapshotProvider.authorizationLabel(for: status));\(failure.detail ?? failure.reasonCode)"
        )
        complete(.failure(failure), step: step)
    }

    private func complete(
        _ outcome: LocationReadOutcome,
        step: SensorStepTrace,
        box: SensorSingleResumeBox<LocationReadReport>? = nil
    ) {
        guard let pendingRequest else { return }
        if let box, pendingRequest.box !== box { return }
        self.pendingRequest = nil
        manager.stopUpdatingLocation()
        pendingRequest.box.resume(
            returning: LocationReadReport(outcome: outcome, steps: pendingRequest.steps + [step])
        )
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let update = LocationDelegateUpdate(locations: locations)
        Task { @MainActor [weak self] in
            self?.handleUpdate(update)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let failure = LocationDelegateFailure(error: error)
        Task { @MainActor [weak self] in
            self?.handleFailure(failure)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange(status)
        }
    }

    private static func accuracyLabel(for accuracy: CLAccuracyAuthorization) -> String {
        switch accuracy {
        case .fullAccuracy: return "full"
        case .reducedAccuracy: return "reduced"
        @unknown default: return "unknown"
        }
    }

    private struct PendingLocationRequest {
        var box: SensorSingleResumeBox<LocationReadReport>
        var requestStartedAt: Date
        var steps: [SensorStepTrace]
    }
}

private enum NativeLocationAuthorization {
    static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        status == .authorizedAlways || status == .authorizedWhenInUse
        #else
        status == .authorizedAlways
        #endif
    }
}

struct NativeDerivedPlace: Equatable, Sendable {
    var placeType: String
    var confidence: Double
    var quality: String
    var source: String
    var poiLookupAvailable: Bool
    var candidates: [PlaceCandidate]
}

struct AmapCoordinate: Equatable, Sendable {
    var longitude: Double
    var latitude: Double
}

struct AmapRawPOI: Decodable, Equatable, Sendable {
    var id: String?
    var name: String?
    var type: String?
    var typecode: String?
    var location: String?
    var distance: String?
    var address: String?

    init(
        id: String? = nil,
        name: String? = nil,
        type: String? = nil,
        typecode: String? = nil,
        location: String? = nil,
        distance: String? = nil,
        address: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.typecode = typecode
        self.location = location
        self.distance = distance
        self.address = address
    }
}

struct AmapRegeo: Decodable, Equatable, Sendable {
    var addressComponent: AmapAddressComponent?
    var pois: [AmapRawPOI]?
    var aois: [AmapRegeoAOI]?

    init(
        addressComponent: AmapAddressComponent? = nil,
        pois: [AmapRawPOI]? = nil,
        aois: [AmapRegeoAOI]? = nil
    ) {
        self.addressComponent = addressComponent
        self.pois = pois
        self.aois = aois
    }

    private enum CodingKeys: String, CodingKey {
        case addressComponent
        case pois
        case aois
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.addressComponent = try? container.decode(AmapAddressComponent.self, forKey: .addressComponent)
        self.pois = try? container.decode([AmapRawPOI].self, forKey: .pois)
        self.aois = try? container.decode([AmapRegeoAOI].self, forKey: .aois)
    }
}

struct AmapAddressComponent: Decodable, Equatable, Sendable {
    var neighborhood: AmapNamedArea?
    var building: AmapNamedArea?

    init(neighborhood: AmapNamedArea? = nil, building: AmapNamedArea? = nil) {
        self.neighborhood = neighborhood
        self.building = building
    }

    private enum CodingKeys: String, CodingKey {
        case neighborhood
        case building
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.neighborhood = try? container.decode(AmapNamedArea.self, forKey: .neighborhood)
        self.building = try? container.decode(AmapNamedArea.self, forKey: .building)
    }
}

struct AmapNamedArea: Decodable, Equatable, Sendable {
    var name: String?
    var type: String?

    init(name: String? = nil, type: String? = nil) {
        self.name = name
        self.type = type
    }
}

struct AmapRegeoAOI: Decodable, Equatable, Sendable {
    var id: String?
    var name: String?
    var type: String?
    var location: String?
    var distance: String?
    var area: String?

    init(
        id: String? = nil,
        name: String? = nil,
        type: String? = nil,
        location: String? = nil,
        distance: String? = nil,
        area: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.location = location
        self.distance = distance
        self.area = area
    }
}

enum AmapPOIClientError: Error, Equatable, Sendable {
    case invalidURL
    case httpStatus(Int)
    case apiFailure(String)
    case invalidCoordinateResponse
    case decodingFailed(String)

    var reasonCode: String {
        switch self {
        case .invalidURL:
            return "amap_invalid_url"
        case .httpStatus(let status):
            return "amap_http_status_\(status)"
        case .apiFailure:
            return "amap_api_failure"
        case .invalidCoordinateResponse:
            return "amap_invalid_coordinate_response"
        case .decodingFailed:
            return "amap_decoding_failed"
        }
    }

    var sanitizedDetail: String {
        switch self {
        case .invalidURL:
            return "AMap request URL could not be constructed."
        case .httpStatus(let status):
            return "AMap request returned HTTP status \(status)."
        case .apiFailure(let info):
            return "AMap API returned failure: \(nativeDiagnosticValue(info))."
        case .invalidCoordinateResponse:
            return "AMap coordinate conversion response did not include a usable coordinate."
        case .decodingFailed(let type):
            return "AMap response decoding failed for \(nativeDiagnosticValue(type))."
        }
    }
}

protocol AmapPOIClient: Sendable {
    func convertToAmapCoordinate(longitude: Double, latitude: Double, apiKey: String) async throws -> AmapCoordinate
    func fetchRegeo(longitude: Double, latitude: Double, radiusM: Double, apiKey: String) async throws -> AmapRegeo
    func fetchAroundPOIs(longitude: Double, latitude: Double, radiusM: Double, apiKey: String) async throws -> [AmapRawPOI]
}

struct LiveAmapPOIClient: AmapPOIClient {
    func convertToAmapCoordinate(longitude: Double, latitude: Double, apiKey: String) async throws -> AmapCoordinate {
        var components = URLComponents(string: "https://restapi.amap.com/v3/assistant/coordinate/convert")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "locations", value: "\(longitude),\(latitude)"),
            URLQueryItem(name: "coordsys", value: "gps")
        ]
        guard let url = components?.url else { throw AmapPOIClientError.invalidURL }
        let response: AmapCoordinateResponse = try await fetch(url)
        guard response.status == "1" else {
            throw AmapPOIClientError.apiFailure(response.info ?? response.infocode ?? "unknown")
        }
        guard let raw = response.locations?.split(separator: ";").first,
              let coordinate = AmapCoordinate(rawLocation: String(raw))
        else {
            throw AmapPOIClientError.invalidCoordinateResponse
        }
        return coordinate
    }

    func fetchAroundPOIs(longitude: Double, latitude: Double, radiusM: Double, apiKey: String) async throws -> [AmapRawPOI] {
        let query = try AmapPlaceKnowledge.bundled().query
        var components = URLComponents(string: "https://restapi.amap.com/v5/place/around")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "location", value: "\(longitude),\(latitude)"),
            URLQueryItem(name: "radius", value: "\(Int(radiusM.rounded()))"),
            URLQueryItem(name: "sortrule", value: "distance"),
            URLQueryItem(name: "page_size", value: "\(query.aroundPageSize)"),
            URLQueryItem(name: "show_fields", value: query.aroundShowFields),
            URLQueryItem(name: "types", value: query.aroundTypesFilter)
        ]
        guard let url = components?.url else { throw AmapPOIClientError.invalidURL }
        let response: AmapPlaceAroundResponse = try await fetch(url)
        guard response.status == "1" else {
            throw AmapPOIClientError.apiFailure(response.info ?? response.infocode ?? "unknown")
        }
        return response.pois ?? []
    }

    func fetchRegeo(longitude: Double, latitude: Double, radiusM: Double, apiKey: String) async throws -> AmapRegeo {
        let query = try AmapPlaceKnowledge.bundled().query
        var components = URLComponents(string: "https://restapi.amap.com/v3/geocode/regeo")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "location", value: "\(longitude),\(latitude)"),
            URLQueryItem(name: "radius", value: "\(Int(radiusM.rounded()))"),
            URLQueryItem(name: "extensions", value: query.regeoExtensions),
            URLQueryItem(name: "roadlevel", value: "\(query.regeoRoadLevel)"),
            URLQueryItem(name: "homeorcorp", value: "\(query.regeoHomeOrCorp)")
        ]
        guard let url = components?.url else { throw AmapPOIClientError.invalidURL }
        let response: AmapRegeoResponse = try await fetch(url)
        guard response.status == "1" else {
            throw AmapPOIClientError.apiFailure(response.info ?? response.infocode ?? "unknown")
        }
        return response.regeocode ?? AmapRegeo()
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AmapPOIClientError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AmapPOIClientError.decodingFailed(String(describing: T.self))
        }
    }

}

final class FakeAmapPOIClient: AmapPOIClient, @unchecked Sendable {
    struct CoordinateConvertRequest: Equatable, Sendable {
        var longitude: Double
        var latitude: Double
    }

    struct RegeoRequest: Equatable, Sendable {
        var longitude: Double
        var latitude: Double
        var radiusM: Double
    }

    struct AroundRequest: Equatable, Sendable {
        var longitude: Double
        var latitude: Double
        var radiusM: Double
    }

    var convertedCoordinate: Result<AmapCoordinate, AmapPOIClientError>?
    var regeo: Result<AmapRegeo, AmapPOIClientError>
    var pois: Result<[AmapRawPOI], AmapPOIClientError>

    private let lock = NSLock()
    private var recordedCoordinateConvertRequests: [CoordinateConvertRequest] = []
    private var recordedRegeoRequests: [RegeoRequest] = []
    private var recordedAroundRequests: [AroundRequest] = []

    init(
        convertedCoordinate: Result<AmapCoordinate, AmapPOIClientError>? = nil,
        regeo: Result<AmapRegeo, AmapPOIClientError> = .success(AmapRegeo()),
        pois: Result<[AmapRawPOI], AmapPOIClientError>
    ) {
        self.convertedCoordinate = convertedCoordinate
        self.regeo = regeo
        self.pois = pois
    }

    var coordinateConvertRequests: [CoordinateConvertRequest] {
        lock.withLock { recordedCoordinateConvertRequests }
    }

    var regeoRequests: [RegeoRequest] {
        lock.withLock { recordedRegeoRequests }
    }

    var aroundRequests: [AroundRequest] {
        lock.withLock { recordedAroundRequests }
    }

    func convertToAmapCoordinate(longitude: Double, latitude: Double, apiKey: String) async throws -> AmapCoordinate {
        _ = apiKey
        lock.withLock {
            recordedCoordinateConvertRequests.append(
                CoordinateConvertRequest(longitude: longitude, latitude: latitude)
            )
        }
        switch convertedCoordinate {
        case .success(let coordinate):
            return coordinate
        case .failure(let error):
            throw error
        case .none:
            return AmapCoordinate(longitude: longitude, latitude: latitude)
        }
    }

    func fetchRegeo(longitude: Double, latitude: Double, radiusM: Double, apiKey: String) async throws -> AmapRegeo {
        _ = apiKey
        lock.withLock {
            recordedRegeoRequests.append(
                RegeoRequest(longitude: longitude, latitude: latitude, radiusM: radiusM)
            )
        }
        switch regeo {
        case .success(let regeo):
            return regeo
        case .failure(let error):
            throw error
        }
    }

    func fetchAroundPOIs(longitude: Double, latitude: Double, radiusM: Double, apiKey: String) async throws -> [AmapRawPOI] {
        _ = apiKey
        lock.withLock {
            recordedAroundRequests.append(
                AroundRequest(longitude: longitude, latitude: latitude, radiusM: radiusM)
            )
        }
        switch pois {
        case .success(let pois):
            return pois
        case .failure(let error):
            throw error
        }
    }
}

enum NativePlaceTypeMapper {
    fileprivate static func derivePlace(
        for location: LocationSample,
        configuration: AmapPOIConfiguration = .disabled,
        client: any AmapPOIClient = LiveAmapPOIClient()
    ) async -> NativeDerivedPlace {
        await derivePlaceWithTrace(for: location, configuration: configuration, client: client).place
    }

    fileprivate static func derivePlaceWithTrace(
        for location: LocationSample,
        configuration: AmapPOIConfiguration = .disabled,
        client: any AmapPOIClient = LiveAmapPOIClient()
    ) async -> (place: NativeDerivedPlace, steps: [SensorStepTrace]) {
        guard configuration.enabled else {
            return unavailableResult(reasonCode: "amap_disabled", detail: "AMap POI lookup is disabled.")
        }
        guard configuration.hasUsableAPIKey else {
            return unavailableResult(reasonCode: "amap_key_missing", detail: "AMap POI lookup has no configured API key.")
        }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 1_000 else {
            return unavailableResult(
                reasonCode: "amap_location_accuracy_too_low",
                detail: "location_accuracy_m=\(Int(max(0, location.horizontalAccuracy).rounded()))"
            )
        }
        let knowledge: AmapPlaceKnowledge
        do {
            knowledge = try AmapPlaceKnowledge.bundled()
        } catch {
            return unavailableResult(
                reasonCode: "amap_knowledge_invalid",
                detail: nativeDiagnosticValue(String(describing: error))
            )
        }

        var steps: [SensorStepTrace] = []
        let coordinate: AmapCoordinate
        switch configuration.inputCoordinateSystem {
        case .autonavi:
            coordinate = AmapCoordinate(longitude: location.longitude, latitude: location.latitude)
            let now = Date()
            steps.append(
                SensorStepTrace(
                    name: "amap.coordinate_convert",
                    startedAt: now,
                    endedAt: now,
                    availability: .available,
                    detail: "input_coordsys=autonavi;conversion=skipped"
                )
            )
        case .gps:
            let startedAt = Date()
            do {
                coordinate = try await client.convertToAmapCoordinate(
                    longitude: location.longitude,
                    latitude: location.latitude,
                    apiKey: configuration.trimmedAPIKey
                )
                steps.append(
                    SensorStepTrace(
                        name: "amap.coordinate_convert",
                        startedAt: startedAt,
                        endedAt: Date(),
                        availability: .available,
                        detail: "input_coordsys=gps;conversion=amap"
                    )
                )
            } catch {
                let diagnostics = amapDiagnostics(for: error)
                steps.append(
                    SensorStepTrace(
                        name: "amap.coordinate_convert",
                        startedAt: startedAt,
                        endedAt: Date(),
                        availability: .unavailable,
                        reasonCode: diagnostics.reasonCode,
                        detail: diagnostics.detail
                    )
                )
                let decision = unavailableDecision(reasonCode: diagnostics.reasonCode)
                return (decision.place, steps + [decisionStep(for: decision)])
            }
        }

        let locationAccuracyM = max(0, location.horizontalAccuracy)
        let sampleAgeS = max(0, Date().timeIntervalSince(location.timestamp))
        let regeoRadiusM = regeoRadiusM(forLocationAccuracy: locationAccuracyM)
        let aroundRadiusM = min(max(configuration.radiusM, 0), knowledge.scoring.aroundRadiusMaxM)
        let maxDistanceM = min(max(max(aroundRadiusM, regeoRadiusM), 0), 500)

        let regeoStartedAt = Date()
        var regeoCandidates: [NativePlaceCandidate] = []
        var regeoContext = NativeRegeoContext()
        do {
            let regeo = try await client.fetchRegeo(
                longitude: coordinate.longitude,
                latitude: coordinate.latitude,
                radiusM: regeoRadiusM,
                apiKey: configuration.trimmedAPIKey
            )
            let regeoMapping = candidates(
                from: regeo,
                origin: coordinate,
                locationAccuracyM: locationAccuracyM,
                sampleAgeS: sampleAgeS,
                maxDistanceM: maxDistanceM
            )
            regeoCandidates = regeoMapping.candidates
            regeoContext = regeoMapping.context
            steps.append(
                SensorStepTrace(
                    name: "amap.regeo",
                    startedAt: regeoStartedAt,
                    endedAt: Date(),
                    availability: regeoCandidates.isEmpty ? .unavailable : .available,
                    reasonCode: regeoCandidates.isEmpty ? "amap_regeo_no_usable_evidence" : nil,
                    detail: regeoTraceDetail(
                        knowledge: knowledge,
                        radiusM: regeoRadiusM,
                        context: regeoContext,
                        candidates: regeoCandidates
                    )
                )
            )
        } catch {
            let diagnostics = amapDiagnostics(for: error)
            steps.append(
                SensorStepTrace(
                    name: "amap.regeo",
                    startedAt: regeoStartedAt,
                    endedAt: Date(),
                    availability: .unavailable,
                    reasonCode: diagnostics.reasonCode,
                    detail: diagnostics.detail
                )
            )
        }

        let poiStartedAt = Date()
        var aroundCandidates: [NativePlaceCandidate] = []
        do {
            let rawPOIs = try await client.fetchAroundPOIs(
                longitude: coordinate.longitude,
                latitude: coordinate.latitude,
                radiusM: aroundRadiusM,
                apiKey: configuration.trimmedAPIKey
            )
            aroundCandidates = candidates(
                from: rawPOIs,
                origin: coordinate,
                locationAccuracyM: locationAccuracyM,
                sampleAgeS: sampleAgeS,
                maxDistanceM: maxDistanceM,
                regeoContext: regeoContext,
                providerKind: .aroundPOI
            )
            steps.append(
                SensorStepTrace(
                    name: "amap.place_around",
                    startedAt: poiStartedAt,
                    endedAt: Date(),
                    availability: aroundCandidates.isEmpty ? .unavailable : .available,
                    reasonCode: aroundCandidates.isEmpty ? "amap_no_usable_poi" : nil,
                    detail: [
                        "radius_m=\(Int(aroundRadiusM.rounded()))",
                        "page_size=\(knowledge.query.aroundPageSize)",
                        "show_fields=\(knowledge.query.aroundShowFields)",
                        "result_count=\(rawPOIs.count)",
                        "usable_count=\(aroundCandidates.count)",
                        "top_candidates=\(candidateTraceSummary(aroundCandidates))"
                    ].joined(separator: ";")
                )
            )
        } catch {
            let diagnostics = amapDiagnostics(for: error)
            steps.append(
                SensorStepTrace(
                    name: "amap.place_around",
                    startedAt: poiStartedAt,
                    endedAt: Date(),
                    availability: .unavailable,
                    reasonCode: diagnostics.reasonCode,
                    detail: diagnostics.detail
                )
            )
        }

        let decision = decide(candidates: regeoCandidates + aroundCandidates)
        return (decision.place, steps + [decisionStep(for: decision)])
    }

    static func testCandidate(
        typecode: String? = nil,
        type: String? = nil,
        name: String? = nil,
        distance: Double,
        rank: Int = 0,
        locationAccuracyM: Double = 0,
        sampleAgeS: TimeInterval = 0
    ) -> NativePlaceCandidate {
        candidate(
            poi: AmapRawPOI(
                name: name,
                type: type,
                typecode: typecode,
                location: nil,
                distance: "\(distance)"
            ),
            distance: distance,
            rank: rank,
            locationAccuracyM: locationAccuracyM,
            sampleAgeS: sampleAgeS,
            coordinate: nil,
            regeoContext: NativeRegeoContext(),
            providerKind: .aroundPOI
        )
    }

    static func testDecision(candidates: [NativePlaceCandidate]) -> NativeDerivedPlace {
        decide(candidates: candidates).place
    }

    private static func candidates(
        from pois: [AmapRawPOI],
        origin: AmapCoordinate,
        locationAccuracyM: Double,
        sampleAgeS: TimeInterval,
        maxDistanceM: Double,
        regeoContext: NativeRegeoContext,
        providerKind: NativePlaceEvidenceKind
    ) -> [NativePlaceCandidate] {
        let maxDistanceM = max(0, min(maxDistanceM, 500))
        return dedupeCandidates(
            pois.enumerated().compactMap { index, poi in
                let coordinate = poi.location.flatMap(AmapCoordinate.init(rawLocation:))
                let distance = distanceM(for: poi, coordinate: coordinate, origin: origin)
                guard distance.isFinite, distance <= maxDistanceM else { return nil }
                return candidate(
                    poi: poi,
                    distance: distance,
                    rank: index,
                    locationAccuracyM: locationAccuracyM,
                    sampleAgeS: sampleAgeS,
                    coordinate: coordinate,
                    regeoContext: regeoContext,
                    providerKind: providerKind
                )
            }
            .filter { $0.placeType != "任意" && $0.confidence > 0 }
        )
    }

    private static func candidates(
        from regeo: AmapRegeo,
        origin: AmapCoordinate,
        locationAccuracyM: Double,
        sampleAgeS: TimeInterval,
        maxDistanceM: Double
    ) -> (candidates: [NativePlaceCandidate], context: NativeRegeoContext) {
        let maxDistanceM = max(0, min(maxDistanceM, 500))
        let aois = regeo.aois ?? []
        let building = regeo.addressComponent?.building
        let neighborhood = regeo.addressComponent?.neighborhood
        let campusContainer = aois.contains { hasContainerEvidence(name: $0.name, type: $0.type) }
            || hasContainerEvidence(name: building?.name, type: building?.type)
            || hasContainerEvidence(name: neighborhood?.name, type: neighborhood?.type)

        var structuralCandidates: [NativePlaceCandidate] = []
        for (index, aoi) in aois.enumerated() {
            let distance = max(0, doubleValue(aoi.distance) ?? 0)
            guard distance <= maxDistanceM else { continue }
            if let candidate = structuralCandidate(
                name: aoi.name,
                type: aoi.type,
                distance: distance,
                rank: index,
                locationAccuracyM: locationAccuracyM,
                sampleAgeS: sampleAgeS,
                providerKind: .regeoAOI,
                campusContainer: campusContainer
            ) {
                structuralCandidates.append(candidate)
            }
        }
        if let building,
           let candidate = structuralCandidate(
            name: building.name,
            type: building.type,
            distance: 0,
            rank: 0,
            locationAccuracyM: locationAccuracyM,
            sampleAgeS: sampleAgeS,
            providerKind: .regeoBuilding,
            campusContainer: campusContainer
           ) {
            structuralCandidates.append(candidate)
        }
        if let neighborhood,
           let candidate = structuralCandidate(
            name: neighborhood.name,
            type: neighborhood.type,
            distance: 0,
            rank: 0,
            locationAccuracyM: locationAccuracyM,
            sampleAgeS: sampleAgeS,
            providerKind: .regeoNeighborhood,
            campusContainer: campusContainer
           ) {
            structuralCandidates.append(candidate)
        }

        let structuralTypes = Set(structuralCandidates.map(\.placeType))
        let context = NativeRegeoContext(
            campusContainer: campusContainer,
            aoiCount: aois.count,
            buildingPresent: building?.hasContent == true,
            neighborhoodPresent: neighborhood?.hasContent == true,
            structuralPlaceTypes: structuralTypes,
            structuralCandidateCount: structuralCandidates.count
        )
        let poiCandidates = candidates(
            from: regeo.pois ?? [],
            origin: origin,
            locationAccuracyM: locationAccuracyM,
            sampleAgeS: sampleAgeS,
            maxDistanceM: maxDistanceM,
            regeoContext: context,
            providerKind: .regeoPOI
        )
        return (dedupeCandidates(structuralCandidates + poiCandidates), context)
    }

    private static func structuralCandidate(
        name: String?,
        type: String?,
        distance: Double,
        rank: Int,
        locationAccuracyM: Double,
        sampleAgeS: TimeInterval,
        providerKind: NativePlaceEvidenceKind,
        campusContainer: Bool
    ) -> NativePlaceCandidate? {
        let knowledge = knowledge()
        let text = [name, type].compactMap { $0 }.joined(separator: " ")
        let nameEvidence = keywordEvidence(forText: name ?? "")
        let typeEvidence = keywordEvidence(forText: type ?? "")
        let combinedEvidence = keywordEvidence(forText: text)
        let providerTypePlaceType = providerTypePlaceType(forTypeText: type)
        let textPlaceType = nameEvidence.strongMatch?.placeType ?? providerTypePlaceType ?? typeEvidence.strongMatch?.placeType
        let containerOnly = textPlaceType == nil && hasContainerEvidence(name: name, type: type)
        guard let placeType = textPlaceType ?? (containerOnly ? "写字楼" : nil) else { return nil }

        var confidence = structuralBaseConfidence(
            placeType: placeType,
            providerKind: providerKind,
            distance: distance,
            campusContainer: campusContainer,
            text: text,
            containerOnly: containerOnly
        )
        confidence -= accuracyPenalty(for: locationAccuracyM) * knowledge.scoring.structural.accuracyPenaltyMultiplier
        if sampleAgeS > 120 { confidence -= knowledge.scoring.structural.staleSamplePenalty }
        confidence = min(max(confidence, 0), knowledge.scoring.structural.maxConfidence)
        guard confidence > 0 else { return nil }

        let tags = evidenceTags(
            keywordEvidence: combinedEvidence,
            typecodeStrength: .none,
            nameConflicts: false,
            typeTextConflicts: false,
            agreesWithRegeo: false
        ) + (campusContainer ? ["campus_container"] : [])
        return NativePlaceCandidate(
            placeType: placeType,
            confidence: confidence,
            source: sourceLabel(for: providerKind, hasTypecodeEvidence: false, hasTypecodeAndFunctionEvidence: false),
            typecode: nil,
            distanceM: distance,
            rank: rank,
            quality: quality(for: confidence),
            evidence: [
                "distance_m=\(Int(distance.rounded()))",
                "rank=\(rank)",
                "provider_kind=\(providerKind.rawValue)",
                "campus_container=\(campusContainer ? 1 : 0)",
                "container_only=\(containerOnly ? 1 : 0)"
            ].joined(separator: ","),
            dedupeKey: "\(providerKind.rawValue):\(placeType):\(rank):\(Int(distance.rounded()))",
            providerKind: providerKind,
            tags: Array(Set(tags)).sorted()
        )
    }

    private static func structuralBaseConfidence(
        placeType: String,
        providerKind: NativePlaceEvidenceKind,
        distance: Double,
        campusContainer: Bool,
        text: String,
        containerOnly: Bool
    ) -> Double {
        let scoring = knowledge().scoring.structural
        if containerOnly {
            switch providerKind {
            case .regeoAOI:
                return distance <= 20 ? scoring.containerAOINear : scoring.containerAOIFar
            case .regeoBuilding, .regeoNeighborhood:
                return scoring.containerBuildingOrNeighborhood
            case .regeoPOI, .aroundPOI:
                return 0
            }
        }
        switch providerKind {
        case .regeoAOI:
            if placeType == "住宅区" { return distance <= 20 ? scoring.regeoAOIResidentialNear : scoring.regeoAOIResidentialFar }
            if placeType == "商场" { return distance <= 20 ? scoring.regeoAOIMallNear : scoring.regeoAOIMallFar }
            return distance <= 20 ? scoring.regeoAOIDefaultNear : scoring.regeoAOIDefaultFar
        case .regeoBuilding:
            if placeType == "住宅区", campusContainer, containsAny(text, knowledge().keywords.dormitoryKeywords) {
                return scoring.regeoBuildingDormResidential
            }
            if placeType == "住宅区" { return scoring.regeoBuildingResidential }
            if placeType == "商场" || placeType == "写字楼" { return scoring.regeoBuildingMallOrOffice }
            return scoring.regeoBuildingDefault
        case .regeoNeighborhood:
            if placeType == "住宅区" { return scoring.regeoNeighborhoodResidential }
            return scoring.regeoNeighborhoodDefault
        case .regeoPOI, .aroundPOI:
            return 0
        }
    }

    private static func decide(candidates rawCandidates: [NativePlaceCandidate]) -> NativePlaceDecision {
        let knowledge = knowledge()
        let candidates = dedupeCandidates(rawCandidates).filter { $0.placeType != "任意" && $0.confidence > 0 }
        guard !candidates.isEmpty else {
            return unavailableDecision(reasonCode: "amap_no_usable_poi")
        }

        let hasStructuralEvidence = candidates.contains { $0.providerKind.isStructuralRegeo }
        let groups = Dictionary(grouping: candidates, by: \.placeType)
        let scored = groups.map { placeType, grouped -> NativePlaceCandidate in
            let sorted = grouped.sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence { return lhs.distanceM < rhs.distanceM }
                return lhs.confidence > rhs.confidence
            }
            let top = sorted[0]
            let second = sorted.dropFirst().first?.confidence ?? 0
            let third = sorted.dropFirst(2).first?.confidence ?? 0
            let providerKinds = Set(grouped.map(\.providerKind))
            let hasStructural = providerKinds.contains { $0.isStructuralRegeo }
            let hasAround = providerKinds.contains(.aroundPOI)
            var aggregate = top.confidence
                + knowledge.scoring.fusion.secondWeight * second
                + knowledge.scoring.fusion.thirdWeight * third
            if hasStructural {
                aggregate += knowledge.scoring.fusion.structuralBonus
            }
            if hasStructural && hasAround {
                aggregate += knowledge.scoring.fusion.structuralAroundBonus
            }
            if hasStructuralEvidence && !hasStructural {
                aggregate -= knowledge.scoring.fusion.missingStructuralPenalty
            }
            aggregate = min(knowledge.scoring.fusion.maxConfidence, max(0, aggregate))
            let source = hasStructural && hasAround ? knowledge.sourceLabels.fusedEvidence : top.source
            let tags = Array(Set(grouped.flatMap(\.tags))).sorted()
            return NativePlaceCandidate(
                placeType: placeType,
                confidence: aggregate,
                source: source,
                typecode: top.typecode,
                distanceM: top.distanceM,
                rank: top.rank,
                quality: quality(for: aggregate),
                evidence: [
                    "aggregate_count=\(sorted.count)",
                    "top_typecode=\(top.typecode ?? "none")",
                    "providers=\(providerKinds.map(\.rawValue).sorted().joined(separator: ","))"
                ].joined(separator: ";"),
                dedupeKey: top.dedupeKey,
                providerKind: top.providerKind,
                tags: tags
            )
        }
        .sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.distanceM < rhs.distanceM }
            return lhs.confidence > rhs.confidence
        }

        guard let winner = scored.first else {
            return unavailableDecision(reasonCode: "amap_no_usable_poi", candidateCount: candidates.count)
        }

        let runnerUp = scored.dropFirst().first
        let margin = winner.confidence - (runnerUp?.confidence ?? 0)
        let finalConfidence = winner.confidence
        let hasCloseRunnerUp = runnerUp.map {
            $0.confidence >= knowledge.scoring.quality.closeRunnerUpMinConfidence
                && margin < knowledge.scoring.quality.closeRunnerUpMaxMargin
        } ?? false

        guard finalConfidence >= knowledge.scoring.quality.minimumAvailableConfidence else {
            return unavailableDecision(
                reasonCode: hasCloseRunnerUp ? "amap_ambiguous_low_confidence" : "amap_low_confidence",
                runnerUp: runnerUp,
                margin: margin,
                candidateCount: candidates.count
            )
        }

        var publicCandidates = scored.prefix(3).map(\.placeCandidate)
        publicCandidates[0] = PlaceCandidate(
            placeType: winner.placeType,
            confidence: finalConfidence,
            distanceM: winner.distanceM,
            source: winner.source,
            quality: hasCloseRunnerUp ? "noisy_mapping" : quality(for: finalConfidence)
        )
        let place = NativeDerivedPlace(
            placeType: winner.placeType,
            confidence: finalConfidence,
            quality: hasCloseRunnerUp ? "noisy_mapping" : quality(for: finalConfidence),
            source: winner.source,
            poiLookupAvailable: true,
            candidates: publicCandidates
        )
        return NativePlaceDecision(
            place: place,
            runnerUp: runnerUp,
            margin: margin,
            candidateCount: candidates.count,
            reasonCode: nil
        )
    }

    private static func candidate(
        poi: AmapRawPOI,
        distance: Double,
        rank: Int,
        locationAccuracyM: Double,
        sampleAgeS: TimeInterval,
        coordinate: AmapCoordinate?,
        regeoContext: NativeRegeoContext,
        providerKind: NativePlaceEvidenceKind
    ) -> NativePlaceCandidate {
        let knowledge = knowledge()
        let text = [poi.name, poi.type].compactMap { $0 }.joined(separator: " ")
        let nameEvidence = keywordEvidence(forText: poi.name ?? "")
        let typeKeywordEvidence = keywordEvidence(forText: poi.type ?? "")
        let combinedEvidence = keywordEvidence(forText: text)
        let providerTypeMatch = providerTypePlaceType(forTypeText: poi.type)
        let typeEvidence = placeTypeForTypecode(
            poi.typecode,
            providerTypePlaceType: providerTypeMatch,
            typeText: poi.type,
            name: poi.name
        )
        let namePlaceType = nameEvidence.strongMatch?.placeType
        let typeTextPlaceType = providerTypeMatch ?? typeKeywordEvidence.strongMatch?.placeType
        let weakNamePlaceType = nameEvidence.weakMatch?.placeType
        let weakTypeTextPlaceType = typeKeywordEvidence.weakMatch?.placeType
        let placeType = typeEvidence?.placeType ?? namePlaceType ?? typeTextPlaceType ?? "任意"

        let hasTypecodeEvidence = typeEvidence != nil
        let hasNameEvidence = namePlaceType != nil
        let hasTypeTextEvidence = typeTextPlaceType != nil
        let typecodeStrength = typeEvidence?.strength ?? .none
        let typecodeIsCoarse = typecodeStrength == .coarse
        let nameMatchesTypecode = hasTypecodeEvidence && namePlaceType == typeEvidence?.placeType
        let typeTextMatchesTypecode = hasTypecodeEvidence && typeTextPlaceType == typeEvidence?.placeType
        let nameRefinesCoarseTypecode = typecodeIsCoarse && hasNameEvidence && namePlaceType == placeType
        let typeTextRefinesCoarseTypecode = typecodeIsCoarse && hasTypeTextEvidence && typeTextPlaceType == placeType
        let weakKeywordMatchesPlaceType = weakNamePlaceType == placeType || weakTypeTextPlaceType == placeType
        let typeTextConflicts = hasTypecodeEvidence && hasTypeTextEvidence && typeTextPlaceType != typeEvidence?.placeType
        let nameConflicts = hasTypecodeEvidence && hasNameEvidence && namePlaceType != typeEvidence?.placeType && !typecodeIsCoarse

        var confidence = distanceScore(for: distance)
        confidence += knowledge.typecodeScore(for: typecodeStrength)
        if nameMatchesTypecode || typeTextMatchesTypecode {
            confidence += knowledge.scoring.poiBoosts.keywordMatchesTypecode
        } else if nameRefinesCoarseTypecode || typeTextRefinesCoarseTypecode {
            confidence += knowledge.scoring.poiBoosts.coarseTypecodeRefinement
        } else if hasTypecodeEvidence && weakKeywordMatchesPlaceType {
            confidence += knowledge.scoring.poiBoosts.weakKeywordAlignedWithTypecode
        } else if hasNameEvidence && !hasTypecodeEvidence {
            confidence += knowledge.scoring.poiBoosts.nameOnly
        } else if hasTypeTextEvidence && !hasTypecodeEvidence {
            confidence += knowledge.scoring.poiBoosts.typeOnly
        }
        if rank == 0 {
            confidence += knowledge.scoring.poiBoosts.topRank
        } else if rank <= 2 {
            confidence += knowledge.scoring.poiBoosts.nearTopRank
        }
        let agreesWithRegeo = regeoContext.structuralPlaceTypes.contains(placeType)
        if agreesWithRegeo {
            confidence += providerKind == .aroundPOI
                ? knowledge.scoring.poiBoosts.aroundRegeoAgreement
                : knowledge.scoring.poiBoosts.regeoPOIAgreement
        }
        confidence -= accuracyPenalty(for: locationAccuracyM)
        if nameConflicts { confidence -= knowledge.scoring.poiPenalties.nameConflict }
        if typeTextConflicts { confidence -= knowledge.scoring.poiPenalties.typeTextConflict }
        if sampleAgeS > 120 { confidence -= knowledge.scoring.poiPenalties.staleSample }

        var cap = candidateCap(
            strength: typecodeStrength,
            hasNameEvidence: hasNameEvidence,
            hasTypeTextEvidence: hasTypeTextEvidence,
            distance: distance
        )
        if providerKind == .regeoPOI {
            cap = min(cap, knowledge.scoring.poiCaps.regeoPOIMax)
        }
        if providerKind == .aroundPOI, agreesWithRegeo {
            cap = knowledge.scoring.poiCaps.aroundRegeoAgreement
        }
        if providerKind == .aroundPOI || providerKind == .regeoPOI {
            cap = min(cap, poiDistanceCap(for: distance))
        }
        confidence = min(max(confidence, 0), cap)

        let source = sourceLabel(
            for: providerKind,
            hasTypecodeEvidence: hasTypecodeEvidence,
            hasTypecodeAndFunctionEvidence: hasTypecodeEvidence && (
                nameMatchesTypecode
                    || typeTextMatchesTypecode
                    || nameRefinesCoarseTypecode
                    || typeTextRefinesCoarseTypecode
                    || weakKeywordMatchesPlaceType
            )
        )
        let tags = evidenceTags(
            keywordEvidence: combinedEvidence,
            typecodeStrength: typecodeStrength,
            nameConflicts: nameConflicts,
            typeTextConflicts: typeTextConflicts,
            agreesWithRegeo: agreesWithRegeo
        )

        return NativePlaceCandidate(
            placeType: placeType,
            confidence: confidence,
            source: source,
            typecode: normalizedTypecode(poi.typecode),
            distanceM: distance,
            rank: rank,
            quality: quality(for: confidence),
            evidence: [
                "typecode=\(normalizedTypecode(poi.typecode) ?? "none")",
                "distance_m=\(Int(distance.rounded()))",
                "rank=\(rank)",
                "source=\(source)",
                "name_conflict=\(nameConflicts)",
                "type_text_conflict=\(typeTextConflicts)",
                "provider_kind=\(providerKind.rawValue)"
            ].joined(separator: ","),
            dedupeKey: makeDedupeKey(poi: poi, coordinate: coordinate, placeType: placeType, providerKind: providerKind),
            providerKind: providerKind,
            tags: tags
        )
    }

    private static func placeTypeForTypecode(
        _ rawTypecode: String?,
        providerTypePlaceType: String?,
        typeText: String?,
        name: String?
    ) -> TypecodeEvidence? {
        let knowledge = knowledge()
        guard let typecode = normalizedTypecode(rawTypecode) else { return nil }
        let nameEvidence = keywordEvidence(forText: name ?? "")
        let typeKeywordEvidence = keywordEvidence(forText: typeText ?? "")
        let strongPlaceTypes = Set(
            [
                nameEvidence.strongMatch?.placeType,
                providerTypePlaceType,
                typeKeywordEvidence.strongMatch?.placeType
            ].compactMap { $0 }
        )
        let weakPlaceTypes = Set(
            [
                nameEvidence.weakMatch?.placeType,
                typeKeywordEvidence.weakMatch?.placeType
            ].compactMap { $0 }
        )
        let hasContainer = hasContainerEvidence(name: name, type: typeText)

        for rule in knowledge.typecodeRules where typecode.hasPrefix(rule.prefix) {
            if let required = rule.requiresStrongKeywordPlaceType, !strongPlaceTypes.contains(required) {
                continue
            }
            if let required = rule.requiresWeakKeywordPlaceType, !weakPlaceTypes.contains(required) {
                continue
            }
            if let required = rule.requiresProviderTypePlaceType, providerTypePlaceType != required {
                continue
            }
            if let required = rule.requiresContainerEvidence, required != hasContainer {
                continue
            }
            return TypecodeEvidence(placeType: rule.placeType, strength: rule.strength)
        }
        return nil
    }

    private static func dedupeCandidates(_ candidates: [NativePlaceCandidate]) -> [NativePlaceCandidate] {
        var bestByKey: [String: NativePlaceCandidate] = [:]
        for candidate in candidates {
            if let current = bestByKey[candidate.dedupeKey] {
                if candidate.confidence > current.confidence || (candidate.confidence == current.confidence && candidate.distanceM < current.distanceM) {
                    bestByKey[candidate.dedupeKey] = candidate
                }
            } else {
                bestByKey[candidate.dedupeKey] = candidate
            }
        }
        return bestByKey.values.sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.distanceM < rhs.distanceM }
            return lhs.confidence > rhs.confidence
        }
    }

    private static func candidateTraceSummary(_ candidates: [NativePlaceCandidate]) -> String {
        let summary = candidates.prefix(3).map { candidate in
            [
                candidate.placeType,
                String(format: "%.2f", candidate.confidence),
                "d=\(Int(candidate.distanceM.rounded()))",
                "typecode=\(candidate.typecode ?? "none")",
                "source=\(candidate.source)"
            ].joined(separator: ",")
        }.joined(separator: "|")
        return summary.isEmpty ? "none" : summary
    }

    private static func keywordEvidence(forText text: String) -> TextKeywordEvidence {
        let knowledge = knowledge()
        let haystack = text.lowercased()
        let strongMatch = knowledge.keywords.strongRules.first { containsAny(haystack, $0.keywords) }.map {
            KeywordMatch(placeType: $0.placeType, tag: $0.tag)
        }
        let weakMatch = knowledge.keywords.weakRules.first { containsAny(haystack, $0.keywords) }.map {
            KeywordMatch(placeType: $0.placeType, tag: $0.tag)
        }
        return TextKeywordEvidence(
            strongMatch: strongMatch,
            weakMatch: weakMatch,
            hasContainer: containsAny(haystack, knowledge.keywords.containerKeywords)
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        let haystack = text.lowercased()
        return needles.contains { containsTerm(haystack, needle: $0.lowercased()) }
    }

    private static func containsTerm(_ haystack: String, needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        if !isASCIIWordLike(needle) {
            return haystack.contains(needle)
        }

        var searchRange: Range<String.Index>? = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            let before = range.lowerBound > haystack.startIndex
                ? haystack[haystack.index(before: range.lowerBound)]
                : nil
            let after = range.upperBound < haystack.endIndex
                ? haystack[range.upperBound]
                : nil
            if isASCIIBoundary(before), isASCIIBoundary(after) {
                return true
            }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return false
    }

    private static func isASCIIWordLike(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == " "
                    || scalar == "-"
            )
        }
    }

    private static func isASCIIBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.unicodeScalars.allSatisfy { !CharacterSet.alphanumerics.contains($0) }
    }

    private static func knowledge() -> AmapPlaceKnowledge {
        try! AmapPlaceKnowledge.bundled()
    }

    private static func providerTypePlaceType(forTypeText typeText: String?) -> String? {
        guard let typeText else { return nil }
        let normalizedSegments = Set(
            typeText
                .split(separator: ";")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let haystack = typeText.lowercased()
        for rule in knowledge().providerTypeRules {
            let matches = rule.matchSegments.contains { term in
                let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalizedSegments.contains(normalized) || containsTerm(haystack, needle: normalized)
            }
            if matches { return rule.placeType }
        }
        return nil
    }

    private static func hasContainerEvidence(name: String?, type: String?) -> Bool {
        containsAny([name, type].compactMap { $0 }.joined(separator: " "), knowledge().keywords.containerKeywords)
    }

    private static func sourceLabel(
        for providerKind: NativePlaceEvidenceKind,
        hasTypecodeEvidence: Bool,
        hasTypecodeAndFunctionEvidence: Bool
    ) -> String {
        let sourceLabels = knowledge().sourceLabels
        switch providerKind {
        case .regeoAOI:
            return sourceLabels.regeoAOI
        case .regeoBuilding:
            return sourceLabels.regeoBuilding
        case .regeoNeighborhood:
            return sourceLabels.regeoNeighborhood
        case .regeoPOI:
            return sourceLabels.regeoPOI
        case .aroundPOI:
            if hasTypecodeAndFunctionEvidence { return sourceLabels.aroundTypecodeName }
            if hasTypecodeEvidence { return sourceLabels.aroundTypecode }
            return sourceLabels.aroundNameKeyword
        }
    }

    private static func evidenceTags(
        keywordEvidence: TextKeywordEvidence,
        typecodeStrength: TypecodeStrength,
        nameConflicts: Bool,
        typeTextConflicts: Bool,
        agreesWithRegeo: Bool
    ) -> [String] {
        var tags: [String] = []
        if let strongMatch = keywordEvidence.strongMatch {
            tags.append(strongMatch.tag)
            tags.append("strong_keyword")
        }
        if let weakMatch = keywordEvidence.weakMatch {
            tags.append("weak_\(weakMatch.tag)")
        }
        if keywordEvidence.hasContainer { tags.append("campus_container") }
        switch typecodeStrength {
        case .strong:
            tags.append("typecode_strong")
        case .mediumStrong:
            tags.append("typecode_medium")
        case .coarse:
            tags.append("typecode_coarse")
        case .container:
            tags.append("typecode_container")
        case .none:
            break
        }
        if nameConflicts || typeTextConflicts { tags.append("conflict") }
        if agreesWithRegeo { tags.append("regeo_agreement") }
        return Array(Set(tags)).sorted()
    }

    private static func regeoRadiusM(forLocationAccuracy accuracy: Double) -> Double {
        let scoring = knowledge().scoring
        return min(scoring.regeoRadiusMaxM, max(scoring.regeoRadiusMinM, accuracy * scoring.regeoRadiusAccuracyMultiplier))
    }

    private static func regeoTraceDetail(
        knowledge: AmapPlaceKnowledge,
        radiusM: Double,
        context: NativeRegeoContext,
        candidates: [NativePlaceCandidate]
    ) -> String {
        [
            "radius_m=\(Int(radiusM.rounded()))",
            "extensions=\(knowledge.query.regeoExtensions)",
            "roadlevel=\(knowledge.query.regeoRoadLevel)",
            "homeorcorp=\(knowledge.query.regeoHomeOrCorp)",
            "aoi_count=\(context.aoiCount)",
            "building_present=\(context.buildingPresent ? 1 : 0)",
            "neighborhood_present=\(context.neighborhoodPresent ? 1 : 0)",
            "campus_container=\(context.campusContainer ? 1 : 0)",
            "structural_usable_count=\(context.structuralCandidateCount)",
            "usable_count=\(candidates.count)",
            "top_candidates=\(candidateTraceSummary(candidates))"
        ].joined(separator: ";")
    }

    private static func distanceM(for poi: AmapRawPOI, coordinate: AmapCoordinate?, origin: AmapCoordinate) -> Double {
        if let distance = doubleValue(poi.distance) {
            return max(0, distance)
        }
        guard let coordinate else { return .infinity }
        let originLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let poiLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return poiLocation.distance(from: originLocation)
    }

    private static func distanceScore(for distance: Double) -> Double {
        for band in knowledge().scoring.poiDistanceScoreBands where distance <= band.maxDistanceM {
            return band.value
        }
        return 0
    }

    private static func poiDistanceCap(for distance: Double) -> Double {
        for band in knowledge().scoring.poiDistanceCapBands where distance <= band.maxDistanceM {
            return band.value
        }
        return 0
    }

    private static func accuracyPenalty(for accuracy: Double) -> Double {
        for band in knowledge().scoring.accuracyPenaltyBands where accuracy <= band.maxAccuracyM {
            return band.penalty
        }
        return knowledge().scoring.accuracyPenaltyBands.last?.penalty ?? 0
    }

    private static func candidateCap(
        strength: TypecodeStrength,
        hasNameEvidence: Bool,
        hasTypeTextEvidence: Bool,
        distance: Double
    ) -> Double {
        let caps = knowledge().scoring.poiCaps
        switch strength {
        case .strong:
            return distance <= 150 ? caps.strongNear : caps.strongFar
        case .mediumStrong:
            return caps.mediumStrong
        case .coarse:
            return (hasNameEvidence || hasTypeTextEvidence) ? caps.coarseWithFunctionEvidence : caps.coarseOnly
        case .container:
            return caps.container
        case .none:
            return hasNameEvidence ? caps.nameOnly : (hasTypeTextEvidence ? caps.typeOnly : 0)
        }
    }

    private static func quality(for confidence: Double) -> String {
        confidence >= knowledge().scoring.quality.exactOrGoodMinConfidence ? "exact_or_good_mapping" : "noisy_mapping"
    }

    private static func normalizedTypecode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    private static func doubleValue(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func makeDedupeKey(
        poi: AmapRawPOI,
        coordinate: AmapCoordinate?,
        placeType: String,
        providerKind: NativePlaceEvidenceKind
    ) -> String {
        let locationKey: String
        if let coordinate {
            locationKey = "\((coordinate.latitude * 10_000).rounded() / 10_000):\((coordinate.longitude * 10_000).rounded() / 10_000)"
        } else {
            locationKey = "no_location"
        }
        let nameKey = abs((poi.name ?? "unknown").hashValue)
        return "\(providerKind.rawValue):\(locationKey):\(normalizedTypecode(poi.typecode) ?? "none"):\(placeType):\(nameKey)"
    }

    private static func unavailableResult(reasonCode: String, detail: String) -> (place: NativeDerivedPlace, steps: [SensorStepTrace]) {
        let now = Date()
        let decision = unavailableDecision(reasonCode: reasonCode)
        return (
            decision.place,
            [
                SensorStepTrace(
                    name: "amap.place_around",
                    startedAt: now,
                    endedAt: now,
                    availability: .unavailable,
                    reasonCode: reasonCode,
                    detail: detail
                ),
                decisionStep(for: decision)
            ]
        )
    }

    private static func unavailableDecision(
        reasonCode: String?,
        runnerUp: NativePlaceCandidate? = nil,
        margin: Double = 0,
        candidateCount: Int = 0
    ) -> NativePlaceDecision {
        NativePlaceDecision(
            place: fallbackPlace(),
            runnerUp: runnerUp,
            margin: margin,
            candidateCount: candidateCount,
            reasonCode: reasonCode
        )
    }

    private static func fallbackPlace() -> NativeDerivedPlace {
        NativeDerivedPlace(
            placeType: "任意",
            confidence: 0,
            quality: "unavailable",
            source: fallbackSourceLabel(),
            poiLookupAvailable: false,
            candidates: []
        )
    }

    private static func fallbackSourceLabel() -> String {
        (try? AmapPlaceKnowledge.bundled().sourceLabels.unavailable) ?? "amap_unavailable"
    }

    private static func decisionStep(for decision: NativePlaceDecision) -> SensorStepTrace {
        let place = decision.place
        let now = Date()
        let runnerUpDetail: String
        if let runnerUp = decision.runnerUp {
            runnerUpDetail = "runner_up=\(runnerUp.placeType),\(String(format: "%.2f", runnerUp.confidence)),source=\(runnerUp.source)"
        } else {
            runnerUpDetail = "runner_up=none"
        }
        return SensorStepTrace(
            name: "amap.place_decision",
            startedAt: now,
            endedAt: now,
            availability: place.poiLookupAvailable ? .available : .unavailable,
            reasonCode: decision.reasonCode,
            detail: [
                "fusion_winner=\(place.placeType)",
                "fusion_runner_up=\(decision.runnerUp?.placeType ?? "none")",
                "chosen_source=\(place.source)",
                "place_type=\(place.placeType)",
                "confidence=\(String(format: "%.2f", place.confidence))",
                "place_quality=\(place.quality)",
                "poi_lookup_available=\(place.poiLookupAvailable ? 1 : 0)",
                "candidate_count=\(decision.candidateCount)",
                "margin=\(String(format: "%.2f", decision.margin))",
                runnerUpDetail
            ].joined(separator: ";")
        )
    }

    private static func amapDiagnostics(for error: Error) -> (reasonCode: String, detail: String) {
        if let error = error as? AmapPOIClientError {
            return (error.reasonCode, error.sanitizedDetail)
        }
        return ("amap_error", "AMap request failed with \(nativeDiagnosticValue(String(describing: type(of: error)))).")
    }
}

fileprivate enum NativePlaceEvidenceKind: String, Equatable, Hashable, Sendable {
    case regeoAOI = "regeo_aoi"
    case regeoBuilding = "regeo_building"
    case regeoNeighborhood = "regeo_neighborhood"
    case regeoPOI = "regeo_poi"
    case aroundPOI = "around_poi"

    var isStructuralRegeo: Bool {
        switch self {
        case .regeoAOI, .regeoBuilding, .regeoNeighborhood:
            return true
        case .regeoPOI, .aroundPOI:
            return false
        }
    }
}

fileprivate struct NativeRegeoContext: Equatable, Sendable {
    var campusContainer: Bool = false
    var aoiCount: Int = 0
    var buildingPresent: Bool = false
    var neighborhoodPresent: Bool = false
    var structuralPlaceTypes: Set<String> = []
    var structuralCandidateCount: Int = 0
}

struct NativePlaceCandidate: Equatable, Sendable {
    var placeType: String
    var confidence: Double
    var source: String
    var typecode: String?
    var distanceM: Double
    var rank: Int
    var quality: String
    var evidence: String
    var dedupeKey: String
    fileprivate var providerKind: NativePlaceEvidenceKind
    fileprivate var tags: [String]

    var placeCandidate: PlaceCandidate {
        PlaceCandidate(
            placeType: placeType,
            confidence: confidence,
            distanceM: distanceM,
            source: source,
            quality: quality
        )
    }
}

private struct NativePlaceDecision: Equatable, Sendable {
    var place: NativeDerivedPlace
    var runnerUp: NativePlaceCandidate?
    var margin: Double
    var candidateCount: Int
    var reasonCode: String?
}

private struct TypecodeEvidence: Equatable, Sendable {
    var placeType: String
    var strength: TypecodeStrength
}

private struct TextKeywordEvidence: Equatable, Sendable {
    var strongMatch: KeywordMatch?
    var weakMatch: KeywordMatch?
    var hasContainer: Bool
}

private struct KeywordMatch: Equatable, Sendable {
    var placeType: String
    var tag: String
}

private struct AmapCoordinateResponse: Decodable {
    var status: String
    var info: String?
    var infocode: String?
    var locations: String?
}

private struct AmapPlaceAroundResponse: Decodable {
    var status: String
    var info: String?
    var infocode: String?
    var pois: [AmapRawPOI]?
}

private struct AmapRegeoResponse: Decodable {
    var status: String
    var info: String?
    var infocode: String?
    var regeocode: AmapRegeo?
}

extension AmapCoordinate {
    init?(rawLocation: String) {
        let parts = rawLocation.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let longitude = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let latitude = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        self.longitude = longitude
        self.latitude = latitude
    }
}

extension AmapNamedArea {
    var hasContent: Bool {
        let text = [name, type].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text.contains { !$0.isEmpty }
    }
}
#endif

enum NativeActivityStateMapper {
    static func map(
        stationary: Bool,
        walking: Bool,
        running: Bool,
        automotive: Bool,
        cycling: Bool,
        unknown: Bool = false,
        confidence: String = "unknown"
    ) -> (activityState: String, rawActivity: String, confidence: String) {
        if unknown { return ("任意", "unknown", confidence) }
        if running || cycling { return ("高速", running ? "running" : "cycling", confidence) }
        if automotive { return ("中速", "automotive", confidence) }
        if walking { return ("慢速", "walking", confidence) }
        if stationary { return ("静止", "stationary", confidence) }
        return ("任意", "unknown", confidence)
    }
}

struct NativeMotionActivitySignal: Equatable, Sendable {
    var stationary: Bool
    var walking: Bool
    var running: Bool
    var automotive: Bool
    var cycling: Bool
    var unknown: Bool
    var confidence: String
    var confidenceScore: Int
    var startedAt: Date
    var source: String

    init(
        stationary: Bool = false,
        walking: Bool = false,
        running: Bool = false,
        automotive: Bool = false,
        cycling: Bool = false,
        unknown: Bool = false,
        confidence: String = "unknown",
        confidenceScore: Int = 0,
        startedAt: Date = Date(timeIntervalSince1970: 0),
        source: String = "test"
    ) {
        self.stationary = stationary
        self.walking = walking
        self.running = running
        self.automotive = automotive
        self.cycling = cycling
        self.unknown = unknown
        self.confidence = confidence
        self.confidenceScore = confidenceScore
        self.startedAt = startedAt
        self.source = source
    }

    var hasKnownActivity: Bool {
        !unknown && (stationary || walking || running || automotive || cycling)
    }

    var flagSummary: String {
        [
            "stationary=\(stationary)",
            "walking=\(walking)",
            "running=\(running)",
            "automotive=\(automotive)",
            "cycling=\(cycling)",
            "unknown=\(unknown)",
            "confidence=\(confidence)",
            "source=\(source)"
        ].joined(separator: ";")
    }
}

struct NativePedometerSignal: Equatable, Sendable {
    var steps: Int
    var distanceM: Double?
    var startedAt: Date
    var endedAt: Date

    init(steps: Int, distanceM: Double? = nil, startedAt: Date, endedAt: Date) {
        self.steps = steps
        self.distanceM = distanceM
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    var detailSummary: String {
        let distance = distanceM.map { String(format: "%.1f", $0) } ?? "none"
        return "steps=\(steps);distance_m=\(distance)"
    }
}

struct NativeMotionActivityDecision: Equatable, Sendable {
    var activityState: String
    var rawActivity: String
    var confidence: String
    var source: String
    var observedAt: Date
    var reasonCode: String
    var detail: String
}

enum NativeMotionActivityResolver {
    static let recentStepWindow: TimeInterval = 90
    static let walkingStepThreshold = 4

    static func resolve(
        live: NativeMotionActivitySignal?,
        history: [NativeMotionActivitySignal],
        pedometer: NativePedometerSignal?,
        now: Date = Date()
    ) -> NativeMotionActivityDecision {
        let knownSignals = [live].compactMap { $0 }.filter(\.hasKnownActivity)
            + bestRecentHistorySignals(from: history)
        let strongestMovement = strongestNonStationary(from: knownSignals)
        if let strongestMovement {
            return decision(from: strongestMovement, reasonCode: "motion_resolved_system_activity")
        }

        if let pedometer, pedometer.steps >= walkingStepThreshold {
            return NativeMotionActivityDecision(
                activityState: "慢速",
                rawActivity: "pedometer_steps",
                confidence: "medium",
                source: "pedometer_steps",
                observedAt: pedometer.endedAt,
                reasonCode: "motion_resolved_pedometer_steps",
                detail: "Recent pedometer steps indicate walking; \(pedometer.detailSummary)."
            )
        }

        if let stationary = knownSignals.first(where: { $0.stationary }) {
            return decision(from: stationary, reasonCode: "motion_resolved_stationary")
        }

        if let pedometer, pedometer.steps == 0 {
            return NativeMotionActivityDecision(
                activityState: "静止",
                rawActivity: "pedometer_no_steps_static_fallback",
                confidence: "low",
                source: "pedometer_no_steps_static_fallback",
                observedAt: pedometer.endedAt,
                reasonCode: "motion_resolved_no_steps_static_fallback",
                detail: "No recent pedometer steps and no classified movement; \(pedometer.detailSummary)."
            )
        }

        return NativeMotionActivityDecision(
            activityState: "任意",
            rawActivity: "unknown",
            confidence: "unknown",
            source: "unresolved",
            observedAt: now,
            reasonCode: "motion_resolution_unknown",
            detail: "No live, recent historical, or pedometer evidence was sufficient to classify activity."
        )
    }

    static func bestRecentHistorySignals(from signals: [NativeMotionActivitySignal]) -> [NativeMotionActivitySignal] {
        guard let best = bestActivity(from: signals) else { return [] }
        return [best]
    }

    static func bestActivity(from signals: [NativeMotionActivitySignal]) -> NativeMotionActivitySignal? {
        signals
            .filter(\.hasKnownActivity)
            .sorted {
                if abs($0.startedAt.timeIntervalSince($1.startedAt)) >= 30 {
                    return $0.startedAt > $1.startedAt
                }
                if $0.confidenceScore != $1.confidenceScore {
                    return $0.confidenceScore > $1.confidenceScore
                }
                return $0.startedAt > $1.startedAt
            }
            .first
    }

    private static func strongestNonStationary(from signals: [NativeMotionActivitySignal]) -> NativeMotionActivitySignal? {
        let nonStationary = signals.filter { $0.running || $0.cycling || $0.automotive || $0.walking }
        return nonStationary.sorted { lhs, rhs in
            let lhsPriority = movementPriority(lhs)
            let rhsPriority = movementPriority(rhs)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            if abs(lhs.startedAt.timeIntervalSince(rhs.startedAt)) >= 30 { return lhs.startedAt > rhs.startedAt }
            if lhs.confidenceScore != rhs.confidenceScore { return lhs.confidenceScore > rhs.confidenceScore }
            return lhs.startedAt > rhs.startedAt
        }.first
    }

    private static func movementPriority(_ signal: NativeMotionActivitySignal) -> Int {
        if signal.running || signal.cycling { return 4 }
        if signal.automotive { return 3 }
        if signal.walking { return 2 }
        if signal.stationary { return 1 }
        return 0
    }

    private static func decision(from signal: NativeMotionActivitySignal, reasonCode: String) -> NativeMotionActivityDecision {
        let mapped = NativeActivityStateMapper.map(
            stationary: signal.stationary,
            walking: signal.walking,
            running: signal.running,
            automotive: signal.automotive,
            cycling: signal.cycling,
            unknown: signal.unknown,
            confidence: signal.confidence
        )
        return NativeMotionActivityDecision(
            activityState: mapped.activityState,
            rawActivity: mapped.rawActivity,
            confidence: mapped.confidence,
            source: signal.source,
            observedAt: signal.startedAt,
            reasonCode: reasonCode,
            detail: "Resolved from \(signal.source); \(signal.flagSummary)."
        )
    }
}

#if os(iOS) && canImport(CoreMotion)
private protocol MotionActivitySnapshotProviding: Sendable {
    func readMotionActivitySnapshot() async -> RawSensorProviderReadOutcome
}

private actor SharedMotionActivitySnapshotProvider: MotionActivitySnapshotProviding {
    private var inFlight: Task<RawSensorProviderReadOutcome, Never>?

    func readMotionActivitySnapshot() async -> RawSensorProviderReadOutcome {
        if let inFlight {
            return await inFlight.value
        }

        let task = Task {
            await SystemMotionActivitySnapshotProvider().readMotionActivitySnapshot()
        }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }
}

private struct SystemMotionActivitySnapshotProvider: MotionActivitySnapshotProviding {
    func readMotionActivitySnapshot() async -> RawSensorProviderReadOutcome {
        var steps: [SensorStepTrace] = []
        let availabilityStartedAt = Date()
        guard CMMotionActivityManager.isActivityAvailable() else {
            let step = SensorStepTrace(
                name: "motion.availability",
                startedAt: availabilityStartedAt,
                endedAt: Date(),
                availability: .unavailable,
                reasonCode: "motion_activity_unavailable",
                detail: "CMMotionActivity samples are unavailable on this device."
            )
            return RawSensorProviderReadOutcome(
                result: .unavailable(.sensorDisabled),
                reasonCode: "motion_activity_unavailable",
                detail: "CMMotionActivity samples are unavailable on this device.",
                steps: [step]
            )
        }
        steps.append(
            SensorStepTrace(
                name: "motion.availability",
                startedAt: availabilityStartedAt,
                endedAt: Date(),
                availability: .available,
                detail: "CMMotionActivity is available."
            )
        )

        let authorizationStartedAt = Date()
        let authorizationStatus = CMMotionActivityManager.authorizationStatus()
        switch authorizationStatus {
        case .authorized:
            steps.append(
                SensorStepTrace(
                    name: "motion.authorization",
                    startedAt: authorizationStartedAt,
                    endedAt: Date(),
                    availability: .available,
                    detail: "authorized"
                )
            )
        case .denied, .restricted:
            let reasonCode = authorizationStatus == .denied ? "motion_permission_denied" : "motion_permission_restricted"
            let detail = authorizationStatus == .denied
                ? "Motion & Fitness permission is denied."
                : "Motion & Fitness permission is restricted by system policy."
            let step = SensorStepTrace(
                name: "motion.authorization",
                startedAt: authorizationStartedAt,
                endedAt: Date(),
                availability: .unavailable,
                reasonCode: reasonCode,
                detail: detail
            )
            steps.append(step)
            return RawSensorProviderReadOutcome(
                result: .unavailable(.permissionDenied),
                reasonCode: reasonCode,
                detail: detail,
                steps: steps
            )
        case .notDetermined:
            let step = SensorStepTrace(
                name: "motion.authorization",
                startedAt: authorizationStartedAt,
                endedAt: Date(),
                availability: .unavailable,
                reasonCode: "motion_permission_not_determined",
                detail: "Motion & Fitness permission has not been granted yet."
            )
            steps.append(step)
            return RawSensorProviderReadOutcome(
                result: .unavailable(.missingSample),
                reasonCode: "motion_permission_not_determined",
                detail: "Motion & Fitness permission has not been granted yet.",
                steps: steps
            )
        @unknown default:
            let step = SensorStepTrace(
                name: "motion.authorization",
                startedAt: authorizationStartedAt,
                endedAt: Date(),
                availability: .unavailable,
                reasonCode: "motion_authorization_unknown",
                detail: "iOS returned an unknown Motion & Fitness authorization state."
            )
            steps.append(step)
            return RawSensorProviderReadOutcome(
                result: .unavailable(.unsupported),
                reasonCode: "motion_authorization_unknown",
                detail: "iOS returned an unknown Motion & Fitness authorization state.",
                steps: steps
            )
        }

        let reader = MotionActivityReader()
        let pedometerReader = MotionPedometerReader()
        async let liveCapture = sensorTraceStep(
            "motion.live_activity",
            operation: { await reader.liveActivity(timeout: 2.5) },
            classify: { outcome in
                switch outcome {
                case .success(let sample):
                    return (.available, nil, sample.flagSummary)
                case .failure(let failure):
                    return (.unavailable, failure.reasonCode, failure.detail)
                }
            }
        )
        async let historyCapture = sensorTraceStep(
            "motion.history_activity",
            operation: { await reader.recentActivities(window: 5 * 60, timeout: 4) },
            classify: { outcome in
                switch outcome {
                case .success(let samples, let totalCount, let usableCount):
                    let best = NativeMotionActivityResolver.bestActivity(from: samples)
                    return (.available, nil, "samples=\(totalCount);usable=\(usableCount);best=\(best?.flagSummary ?? "none")")
                case .failure(let failure):
                    return (.unavailable, failure.reasonCode, failure.detail)
                }
            }
        )
        async let pedometerCapture = sensorTraceStep(
            "motion.pedometer_recent",
            operation: { await pedometerReader.recentPedometerData(window: NativeMotionActivityResolver.recentStepWindow, timeout: 2) },
            classify: { outcome in
                switch outcome {
                case .success(let pedometer):
                    return (.available, nil, pedometer.detailSummary)
                case .failure(let failure):
                    return (.unavailable, failure.reasonCode, failure.detail)
                }
            }
        )

        let (liveOutcome, liveStep) = await liveCapture
        let (historyOutcome, historyStep) = await historyCapture
        let (pedometerOutcome, pedometerStep) = await pedometerCapture
        steps.append(contentsOf: [liveStep, historyStep, pedometerStep])

        let live: NativeMotionActivitySignal? = {
            if case .success(let sample) = liveOutcome { return sample }
            return nil
        }()
        let history: [NativeMotionActivitySignal] = {
            if case .success(let samples, _, _) = historyOutcome { return samples }
            return []
        }()
        let pedometer: NativePedometerSignal? = {
            if case .success(let signal) = pedometerOutcome { return signal }
            return nil
        }()

        let decisionStartedAt = Date()
        let decision = NativeMotionActivityResolver.resolve(live: live, history: history, pedometer: pedometer, now: decisionStartedAt)
        steps.append(
            SensorStepTrace(
                name: "motion.resolve_activity",
                startedAt: decisionStartedAt,
                endedAt: Date(),
                availability: decision.activityState == "任意" ? .unavailable : .available,
                reasonCode: decision.activityState == "任意" ? decision.reasonCode : nil,
                detail: "activity_state=\(decision.activityState);raw=\(decision.rawActivity);source=\(decision.source);confidence=\(decision.confidence);reason=\(decision.reasonCode);\(decision.detail)"
            )
        )

        guard decision.activityState != "任意" else {
            return RawSensorProviderReadOutcome(
                result: .unavailable(.missingSample),
                reasonCode: decision.reasonCode,
                detail: decision.detail,
                steps: steps
            )
        }

        return RawSensorProviderReadOutcome(
            result: .reading(
                RawSensorReading(
                    observedAt: decision.observedAt,
                    freshnessWindow: 600,
                    values: [
                        "activity_state": .string(decision.activityState),
                        "raw_motion_activity": .string(decision.rawActivity),
                        "raw_motion_confidence": .string(decision.confidence),
                        "activity_state_source": .string(decision.source),
                    ]
                )
            ),
            steps: steps
        )
    }
}

private enum MotionSignalReadOutcome: Sendable {
    case success(NativeMotionActivitySignal)
    case failure(NativeSensorFailure)
}

private enum MotionHistoryReadOutcome: Sendable {
    case success([NativeMotionActivitySignal], totalCount: Int, usableCount: Int)
    case failure(NativeSensorFailure)
}

private enum MotionPedometerReadOutcome: Sendable {
    case success(NativePedometerSignal)
    case failure(NativeSensorFailure)
}

private final class MotionActivityReader: @unchecked Sendable {
    private let manager = CMMotionActivityManager()

    func liveActivity(timeout: TimeInterval = 2.5) async -> MotionSignalReadOutcome {
        await withCheckedContinuation { continuation in
            let box = SensorSingleResumeBox(continuation) { [self] in
                self.manager.stopActivityUpdates()
            }
            manager.startActivityUpdates(to: .main) { activity in
                guard let activity else { return }
                box.resume(returning: .success(NativeMotionActivitySignal(activity, source: "live_activity")))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                box.resume(
                    returning: .failure(
                        NativeSensorFailure(
                            reason: .deadlineExceeded,
                            reasonCode: "motion_live_timeout",
                            detail: "CMMotionActivity live updates did not return within \(String(format: "%.1f", timeout))s."
                        )
                    )
                )
            }
        }
    }

    func recentActivities(window: TimeInterval = 5 * 60, timeout: TimeInterval = 4) async -> MotionHistoryReadOutcome {
        await withCheckedContinuation { continuation in
            let box = SensorSingleResumeBox(continuation)
            let endDate = Date()
            let startDate = endDate.addingTimeInterval(-window)
            manager.queryActivityStarting(from: startDate, to: endDate, to: .main) { activities, error in
                if let error {
                    box.resume(
                        returning: .failure(
                            NativeSensorFailure(
                                reason: .missingSample,
                                reasonCode: "motion_history_error:\(String(describing: type(of: error)))",
                                detail: error.localizedDescription
                            )
                        )
                    )
                    return
                }

                let activities = activities ?? []
                guard !activities.isEmpty else {
                    box.resume(
                        returning: .failure(
                            NativeSensorFailure(
                                reason: .missingSample,
                                reasonCode: "motion_history_no_samples",
                                detail: "CMMotionActivity returned no samples in the last \(Int(window / 60)) minutes."
                            )
                        )
                    )
                    return
                }

                let samples = activities.map { NativeMotionActivitySignal($0, source: "history_activity") }
                let usableCount = samples.filter(\.hasKnownActivity).count
                guard usableCount > 0 else {
                    box.resume(
                        returning: .failure(
                            NativeSensorFailure(
                                reason: .missingSample,
                                reasonCode: "motion_history_no_usable_samples",
                                detail: "CMMotionActivity returned \(activities.count) samples, but none mapped to a known backend activity."
                            )
                        )
                    )
                    return
                }
                box.resume(returning: .success(samples, totalCount: activities.count, usableCount: usableCount))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                box.resume(
                    returning: .failure(
                        NativeSensorFailure(
                            reason: .deadlineExceeded,
                            reasonCode: "motion_history_timeout",
                            detail: "CMMotionActivity history query did not return within \(Int(timeout))s."
                        )
                    )
                )
            }
        }
    }
}

private final class MotionPedometerReader: @unchecked Sendable {
    private let pedometer = CMPedometer()

    func recentPedometerData(window: TimeInterval, timeout: TimeInterval = 2) async -> MotionPedometerReadOutcome {
        guard CMPedometer.isStepCountingAvailable() else {
            return .failure(
                NativeSensorFailure(
                    reason: .sensorDisabled,
                    reasonCode: "pedometer_unavailable",
                    detail: "CMPedometer step counting is unavailable on this device."
                )
            )
        }

        switch CMPedometer.authorizationStatus() {
        case .authorized:
            break
        case .denied, .restricted:
            return .failure(
                NativeSensorFailure(
                    reason: .permissionDenied,
                    reasonCode: "pedometer_permission_denied",
                    detail: "Motion & Fitness pedometer permission is denied or restricted."
                )
            )
        case .notDetermined:
            return .failure(
                NativeSensorFailure(
                    reason: .missingSample,
                    reasonCode: "pedometer_permission_not_determined",
                    detail: "Motion & Fitness pedometer permission has not been granted yet."
                )
            )
        @unknown default:
            return .failure(
                NativeSensorFailure(
                    reason: .unsupported,
                    reasonCode: "pedometer_authorization_unknown",
                    detail: "iOS returned an unknown pedometer authorization state."
                )
            )
        }

        return await withCheckedContinuation { continuation in
            let box = SensorSingleResumeBox(continuation)
            let endDate = Date()
            let startDate = endDate.addingTimeInterval(-window)
            pedometer.queryPedometerData(from: startDate, to: endDate) { data, error in
                if let error {
                    box.resume(
                        returning: .failure(
                            NativeSensorFailure(
                                reason: .missingSample,
                                reasonCode: "pedometer_query_error:\(String(describing: type(of: error)))",
                                detail: error.localizedDescription
                            )
                        )
                    )
                    return
                }
                guard let data else {
                    box.resume(
                        returning: .failure(
                            NativeSensorFailure(
                                reason: .missingSample,
                                reasonCode: "pedometer_no_samples",
                                detail: "CMPedometer returned no recent step samples."
                            )
                        )
                    )
                    return
                }
                box.resume(
                    returning: .success(
                        NativePedometerSignal(
                            steps: data.numberOfSteps.intValue,
                            distanceM: data.distance?.doubleValue,
                            startedAt: startDate,
                            endedAt: endDate
                        )
                    )
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                box.resume(
                    returning: .failure(
                        NativeSensorFailure(
                            reason: .deadlineExceeded,
                            reasonCode: "pedometer_query_timeout",
                            detail: "CMPedometer query did not return within \(Int(timeout))s."
                        )
                    )
                )
            }
        }
    }
}

private extension NativeMotionActivitySignal {
    init(_ activity: CMMotionActivity, source: String) {
        self.init(
            stationary: activity.stationary,
            walking: activity.walking,
            running: activity.running,
            automotive: activity.automotive,
            cycling: activity.cycling,
            unknown: activity.unknown,
            confidence: NativeMotionActivityMapper.confidenceLabel(activity.confidence),
            confidenceScore: NativeMotionActivityMapper.confidenceScore(activity.confidence),
            startedAt: activity.startDate,
            source: source
        )
    }
}

enum NativeMotionActivityMapper {
    fileprivate static func confidenceScore(_ confidence: CMMotionActivityConfidence) -> Int {
        switch confidence {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        @unknown default: return 0
        }
    }

    fileprivate static func confidenceLabel(_ confidence: CMMotionActivityConfidence) -> String {
        switch confidence {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        @unknown default: return "unknown"
        }
    }
}
#endif

enum NativeNoiseMapper {
    static func label(forAveragePowerDBFS averagePower: Double) -> String {
        if averagePower < -45 { return "安静" }
        if averagePower < -25 { return "普通" }
        return "嘈杂"
    }
}

#if os(iOS) && canImport(AVFAudio)
private protocol MicrophoneNoiseSnapshotProviding: Sendable {
    func readNoiseSnapshot() async -> RawSensorProviderReadOutcome
}

private struct SystemMicrophoneNoiseSnapshotProvider: MicrophoneNoiseSnapshotProviding {
    func readNoiseSnapshot() async -> RawSensorProviderReadOutcome {
        var steps: [SensorStepTrace] = []
        let permissionStartedAt = Date()

        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            let detail = "Microphone permission has not been granted yet."
            steps.append(
                SensorStepTrace(
                    name: "microphone.permission",
                    startedAt: permissionStartedAt,
                    endedAt: Date(),
                    availability: .unavailable,
                    reasonCode: "microphone_permission_not_determined",
                    detail: detail
                )
            )
            return RawSensorProviderReadOutcome(
                result: .unavailable(.missingSample),
                reasonCode: "microphone_permission_not_determined",
                detail: detail,
                steps: steps
            )
        case .denied:
            let detail = "Microphone permission is denied."
            steps.append(
                SensorStepTrace(
                    name: "microphone.permission",
                    startedAt: permissionStartedAt,
                    endedAt: Date(),
                    availability: .unavailable,
                    reasonCode: "microphone_permission_denied",
                    detail: detail
                )
            )
            return RawSensorProviderReadOutcome(
                result: .unavailable(.permissionDenied),
                reasonCode: "microphone_permission_denied",
                detail: detail,
                steps: steps
            )
        case .granted:
            steps.append(
                SensorStepTrace(
                    name: "microphone.permission",
                    startedAt: permissionStartedAt,
                    endedAt: Date(),
                    availability: .available,
                    detail: "granted"
                )
            )
        @unknown default:
            let detail = "iOS returned an unknown microphone permission state."
            steps.append(
                SensorStepTrace(
                    name: "microphone.permission",
                    startedAt: permissionStartedAt,
                    endedAt: Date(),
                    availability: .unavailable,
                    reasonCode: "microphone_permission_unknown",
                    detail: detail
                )
            )
            return RawSensorProviderReadOutcome(
                result: .unavailable(.unsupported),
                reasonCode: "microphone_permission_unknown",
                detail: detail,
                steps: steps
            )
        }

        let (sampleResult, meteringStep) = await sensorTraceStep(
            "microphone.metering",
            operation: { await MicrophoneLevelMeter().sample(duration: 1.0) },
            classify: { result in
                switch result {
                case .success(let sample):
                    return (.available, nil, "avg_dbfs=\(Self.rounded(sample.averagePowerDBFS));peak_dbfs=\(Self.rounded(sample.peakPowerDBFS))")
                case .failure(let failure):
                    return (.unavailable, failure.reasonCode, failure.detail)
                }
            }
        )
        steps.append(meteringStep)

        switch sampleResult {
        case .success(let sample):
            let classifyStartedAt = Date()
            let noiseClass = NativeNoiseMapper.label(forAveragePowerDBFS: sample.averagePowerDBFS)
            steps.append(
                SensorStepTrace(
                    name: "microphone.classify_noise",
                    startedAt: classifyStartedAt,
                    endedAt: Date(),
                    availability: .available,
                    detail: "noise_class=\(noiseClass)"
                )
            )
            return RawSensorProviderReadOutcome(
                result: .reading(
                    RawSensorReading(
                        observedAt: Date(),
                        freshnessWindow: 120,
                        values: [
                            "noise_class": .string(noiseClass),
                            "raw_noise_avg_dbfs": .double(sample.averagePowerDBFS),
                            "raw_noise_peak_dbfs": .double(sample.peakPowerDBFS),
                            "noise_sample_count": .int(sample.sampleCount),
                        ]
                    )
                ),
                steps: steps
            )
        case .failure(let failure):
            return RawSensorProviderReadOutcome(
                result: .unavailable(failure.reason),
                reasonCode: failure.reasonCode,
                detail: failure.detail,
                steps: steps
            )
        }
    }

    private static func rounded(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

private struct MicrophoneLevelSample: Sendable, Equatable {
    var averagePowerDBFS: Double
    var peakPowerDBFS: Double
    var sampleCount: Int
}

@MainActor
private final class MicrophoneLevelMeter {
    func sample(duration: TimeInterval) async -> Result<MicrophoneLevelSample, NativeSensorFailure> {
        let session = AVAudioSession.sharedInstance()
        let previousCategory = session.category
        let previousMode = session.mode
        let previousOptions = session.categoryOptions
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoPOC-noise-\(UUID().uuidString).caf")

        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return .failure(
                NativeSensorFailure(
                    reason: .missingSample,
                    reasonCode: "microphone_session_error",
                    detail: error.localizedDescription
                )
            )
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatAppleIMA4),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
                try? FileManager.default.removeItem(at: fileURL)
                return .failure(
                    NativeSensorFailure(
                        reason: .missingSample,
                        reasonCode: "microphone_metering_failed",
                        detail: "AVAudioRecorder refused to start recording."
                    )
                )
            }

            let sampleInterval = 0.1
            let sampleLimit = max(1, Int((duration / sampleInterval).rounded(.up)))
            var averageReadings: [Float] = []
            var peakReadings: [Float] = []
            for _ in 0..<sampleLimit {
                try? await Task.sleep(for: .seconds(sampleInterval))
                recorder.updateMeters()
                averageReadings.append(recorder.averagePower(forChannel: 0))
                peakReadings.append(recorder.peakPower(forChannel: 0))
            }
            recorder.stop()
            try? FileManager.default.removeItem(at: fileURL)
            try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions)

            guard !averageReadings.isEmpty else {
                return .failure(
                    NativeSensorFailure(
                        reason: .missingSample,
                        reasonCode: "microphone_no_samples",
                        detail: "Microphone metering produced no samples."
                    )
                )
            }

            let averagePower = averageReadings.map(Double.init).reduce(0, +) / Double(averageReadings.count)
            let peakPower = peakReadings.map(Double.init).max() ?? averagePower
            return .success(
                MicrophoneLevelSample(
                    averagePowerDBFS: averagePower,
                    peakPowerDBFS: peakPower,
                    sampleCount: averageReadings.count
                )
            )
        } catch {
            try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            try? FileManager.default.removeItem(at: fileURL)
            return .failure(
                NativeSensorFailure(
                    reason: .missingSample,
                    reasonCode: "microphone_metering_failed",
                    detail: error.localizedDescription
                )
            )
        }
    }
}
#endif

enum NativeHealthValueMapper {
    static func heartRateZone(bpm: Double, previousBpm: Double? = nil) -> String {
        if let previousBpm, abs(bpm - previousBpm) >= 20 { return "波动" }
        if bpm < 80 { return "静息" }
        if bpm < 105 { return "稍高" }
        return "高"
    }

    static func sleepQuality(asleepMinutes: Int, awakeMinutes: Int) -> String {
        if asleepMinutes >= 420 && awakeMinutes <= 30 { return "好" }
        if asleepMinutes >= 300 { return "一般" }
        return "差"
    }
}

#if os(iOS) && canImport(HealthKit)
private final class HealthKitSnapshotReader: @unchecked Sendable {
    private let store = HKHealthStore()

    func readHealthValues() async -> [String: JSONValue] {
        await readHealthValuesWithTrace().0
    }

    func readHealthValuesWithTrace() async -> ([String: JSONValue], [SensorStepTrace]) {
        async let heartRateCapture = sensorTraceStep(
            "health.heart_rate",
            operation: { await self.latestHeartRate() },
            classify: { snapshot in
                snapshot == nil
                    ? (.unavailable, "health_heart_rate_no_samples", "No heart rate samples in the last 6 hours.")
                    : (.available, nil, "captured")
            }
        )
        async let stepsCapture = sensorTraceStep(
            "health.steps_10min",
            operation: { await self.stepsLast10Minutes() },
            classify: { steps in
                steps == nil
                    ? (.unavailable, "health_steps_no_samples", "No step count samples in the last 10 minutes.")
                    : (.available, nil, "steps=\(steps ?? 0)")
            }
        )
        async let workoutCapture = sensorTraceStep(
            "health.workout_24h",
            operation: { await self.recentWorkoutMinutes24h() },
            classify: { minutes in
                minutes == nil
                    ? (.unavailable, "health_workout_no_samples", "No workout samples in the last 24 hours.")
                    : (.available, nil, "minutes=\(minutes ?? 0)")
            }
        )
        async let sleepCapture = sensorTraceStep(
            "health.sleep_36h",
            operation: { await self.latestSleepQuality() },
            classify: { sleep in
                sleep == nil
                    ? (.unavailable, "health_sleep_no_samples", "No sleep analysis samples in the last 36 hours.")
                    : (.available, nil, "quality=\(sleep ?? "")")
            }
        )

        let (heartRate, heartRateStep) = await heartRateCapture
        let (steps, stepsStep) = await stepsCapture
        let (minutes, workoutStep) = await workoutCapture
        let (sleep, sleepStep) = await sleepCapture

        var values: [String: JSONValue] = [:]

        if let heartRate {
            values["heart_rate_zone"] = .string(NativeHealthValueMapper.heartRateZone(bpm: heartRate.bpm, previousBpm: heartRate.previousBpm))
            values["heart_rate_available"] = .int(1)
        } else {
            values["heart_rate_available"] = .int(0)
        }

        if let steps {
            values["steps_last_10min"] = .int(steps)
        }

        if let minutes {
            values["recent_workout_minutes_24h"] = .int(minutes)
        }

        if let sleep {
            values["sleep_quality"] = .string(sleep)
        }

        if values.count == 1 && values["heart_rate_available"] == .int(0) {
            return ([:], [heartRateStep, stepsStep, workoutStep, sleepStep])
        }
        return (values, [heartRateStep, stepsStep, workoutStep, sleepStep])
    }

    private struct HeartRateSnapshot {
        var bpm: Double
        var previousBpm: Double?
    }

    private func latestHeartRate() async -> HeartRateSnapshot? {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-6 * 60 * 60), end: Date())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 2, sortDescriptors: [sort]) { _, samples, _ in
                let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                guard let latest = quantitySamples.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let previous = quantitySamples.dropFirst().first?.quantity.doubleValue(for: heartRateUnit)
                continuation.resume(
                    returning: HeartRateSnapshot(
                        bpm: latest.quantity.doubleValue(for: heartRateUnit),
                        previousBpm: previous
                    )
                )
            }
            store.execute(query)
        }
    }

    private func stepsLast10Minutes() async -> Int? {
        guard let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-10 * 60), end: Date())
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, _ in
                guard let count = statistics?.sumQuantity()?.doubleValue(for: .count()) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: max(0, Int(count.rounded())))
            }
            store.execute(query)
        }
    }

    private func recentWorkoutMinutes24h() async -> Int? {
        let type = HKObjectType.workoutType()
        let start = Date().addingTimeInterval(-24 * 60 * 60)
        let end = Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let workouts = (samples as? [HKWorkout]) ?? []
                guard !workouts.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let minutes = workouts.reduce(0.0) { total, workout in
                    let overlapStart = max(workout.startDate, start)
                    let overlapEnd = min(workout.endDate, end)
                    return total + max(0, overlapEnd.timeIntervalSince(overlapStart) / 60)
                }
                continuation.resume(returning: max(0, Int(minutes.rounded())))
            }
            store.execute(query)
        }
    }

    private func latestSleepQuality() async -> String? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-36 * 60 * 60), end: Date())
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let sleepSamples = (samples as? [HKCategorySample]) ?? []
                let buckets = Self.sleepBuckets(from: sleepSamples)
                guard buckets.asleepMinutes > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: NativeHealthValueMapper.sleepQuality(
                        asleepMinutes: buckets.asleepMinutes,
                        awakeMinutes: buckets.awakeMinutes
                    )
                )
            }
            store.execute(query)
        }
    }

    private static func sleepBuckets(from samples: [HKCategorySample]) -> (asleepMinutes: Int, awakeMinutes: Int) {
        let asleepValues = sleepAsleepRawValues()
        var asleep = 0.0
        var awake = 0.0
        for sample in samples {
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60
            if asleepValues.contains(sample.value) {
                asleep += minutes
            } else if sample.value == HKCategoryValueSleepAnalysis.awake.rawValue {
                awake += minutes
            }
        }
        return (max(0, Int(asleep.rounded())), max(0, Int(awake.rounded())))
    }

    private static func sleepAsleepRawValues() -> Set<Int> {
        if #available(iOS 16.0, *) {
            return Set([
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            ])
        }
        return []
    }
}
#endif

enum NativeWeatherMapper {
    static func label(for condition: Any) -> String {
        let raw = String(describing: condition).lowercased()
        if raw.contains("thunder") { return "雷雨" }
        if raw.contains("snow") || raw.contains("sleet") { return "雪" }
        if raw.contains("rain") || raw.contains("drizzle") { return "小雨" }
        if raw.contains("cloud") || raw.contains("overcast") { return "多云" }
        if raw.contains("fog") || raw.contains("haze") || raw.contains("smok") { return "雾" }
        if raw.contains("wind") { return "大风" }
        if raw.contains("clear") || raw.contains("sun") { return "晴" }
        return "多云"
    }
}

private final class SensorSingleResumeBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private let onResume: () -> Void

    init(_ continuation: CheckedContinuation<Value, Never>, onResume: @escaping () -> Void = {}) {
        self.continuation = continuation
        self.onResume = onResume
    }

    func resume(returning value: Value) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(returning: value)
        onResume()
    }
}
