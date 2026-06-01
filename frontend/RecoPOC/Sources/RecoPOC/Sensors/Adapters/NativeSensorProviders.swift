import Foundation

#if canImport(Network)
import Network
#endif

#if canImport(CoreLocation)
import CoreLocation
#endif

#if canImport(MapKit)
import MapKit
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

public struct NativeSensorProviderCatalog {
    public init() {}

    public func makeProviders() -> [any RawSensorReadingProvider] {
        #if canImport(CoreLocation)
        let sharedLocationReader = SharedLocationReader()
        let locationProvider = SystemLocationSnapshotProvider(locationReader: sharedLocationReader)
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

    public init() {
        self.locationReader = SharedLocationReader()
    }

    init(locationReader: any LocationReading = SharedLocationReader()) {
        self.locationReader = locationReader
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
                    return (.available, nil, "accuracy_m=\(Int(max(0, location.horizontalAccuracy.rounded())))")
                case .failure(let failure):
                    return (.unavailable, failure.reasonCode, failure.detail)
                }
            }
        )
        var steps = [locationStep]
        steps.append(contentsOf: locationReport.steps)

        switch locationReport.outcome {
        case .success(let location):
            let (place, placeSteps) = await NativePlaceTypeMapper.derivePlaceWithTrace(for: location)
            steps.append(contentsOf: placeSteps)
            return RawSensorProviderReadOutcome(
                result: .reading(
                    RawSensorReading(
                        observedAt: location.timestamp,
                        freshnessWindow: 60,
                        values: [
                            "latitude": .double(location.latitude),
                            "longitude": .double(location.longitude),
                            "location_accuracy_m": .double(max(0, location.horizontalAccuracy)),
                            "place_type": .string(place.placeType),
                            "place_type_confidence": .double(place.confidence),
                            "place_type_quality": .string(place.quality),
                            "place_source": .string(place.source),
                            "poi_lookup_available": .int(place.poiLookupAvailable ? 1 : 0),
                        ]
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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: max(0, horizontalAccuracy),
            verticalAccuracy: -1,
            timestamp: timestamp
        )
    }

    init(_ location: CLLocation) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.timestamp = location.timestamp
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
            .map(LocationSample.init)
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
}

private struct NativePlaceProbeResult: Sendable {
    var candidates: [NativePlaceCandidate]
    var trace: SensorStepTrace
}

struct NativePlaceCandidate: Equatable, Sendable {
    var placeType: String
    var confidence: Double
    var source: String
    var query: String?
    var itemName: String?
    var categoryRaw: String?
    var distanceM: Double
    var rank: Int
    var evidence: String
    var dedupeKey: String
}

private struct NativePlaceDecision: Equatable, Sendable {
    var place: NativeDerivedPlace
    var runnerUp: NativePlaceCandidate?
    var margin: Double
    var candidateCount: Int
    var reasonCode: String?
}

enum NativePlaceTypeMapper {
    fileprivate static func derivePlace(for location: LocationSample) async -> NativeDerivedPlace {
        await derivePlaceWithTrace(for: location).place
    }

    fileprivate static func derivePlaceWithTrace(for location: LocationSample) async -> (place: NativeDerivedPlace, steps: [SensorStepTrace]) {
        #if canImport(MapKit)
        if #available(iOS 14.0, macOS 11.0, *) {
            async let reverseGeocodeProbe = reverseGeocodeProbe(for: location)
            let queryProbes = await queryProbeBatch(for: location, radius: 500)
            let probes = await [reverseGeocodeProbe] + queryProbes
            let candidates = dedupeCandidates(probes.flatMap(\.candidates))
            let decision = decide(candidates: candidates)
            return (decision.place, probes.map(\.trace) + [decisionStep(for: decision)])
        }
        #endif

        let fallback = fallbackPlace()
        let now = Date()
        return (
            fallback,
            [
                SensorStepTrace(
                    name: "place.ab_decision",
                    startedAt: now,
                    endedAt: now,
                    availability: .unavailable,
                    reasonCode: "mapkit_unsupported",
                    detail: "MapKit POI lookup is not available in this build;chosen_source=\(fallback.source)"
                )
            ]
        )
    }

    #if canImport(MapKit)
    @MainActor
    private static func queryProbeBatch(for location: LocationSample, radius: CLLocationDistance) async -> [NativePlaceProbeResult] {
        async let restaurant = queryProbe(for: location, query: "餐厅", radius: radius)
        async let coffee = queryProbe(for: location, query: "咖啡", radius: radius)
        async let hotel = queryProbe(for: location, query: "酒店", radius: radius)
        async let mall = queryProbe(for: location, query: "商场", radius: radius)
        async let park = queryProbe(for: location, query: "公园", radius: radius)
        async let library = queryProbe(for: location, query: "图书馆", radius: radius)
        async let metro = queryProbe(for: location, query: "地铁站", radius: radius)
        async let airport = queryProbe(for: location, query: "机场", radius: radius)
        async let school = queryProbe(for: location, query: "学校", radius: radius)
        async let institute = queryProbe(for: location, query: "研究院", radius: radius)
        async let office = queryProbe(for: location, query: "写字楼", radius: radius)
        return await [
            restaurant,
            coffee,
            hotel,
            mall,
            park,
            library,
            metro,
            airport,
            school,
            institute,
            office
        ].sorted { $0.trace.name < $1.trace.name }
    }

    @MainActor
    private static func queryProbe(for location: LocationSample, query: String, radius: CLLocationDistance) async -> NativePlaceProbeResult {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )
        request.resultTypes = .pointOfInterest
        return await runMapKitSearch(
            name: "mapkit.query_probe.\(query)",
            search: MKLocalSearch(request: request),
            location: location,
            source: "mapkit_query_probe",
            query: query,
            requestDetail: "query=\(nativeDiagnosticValue(query));region_m=\(Int(radius * 2));result_types=point_of_interest;poi_filter=not_set"
        )
    }

    @MainActor
    private static func runMapKitSearch(
        name: String,
        search: MKLocalSearch,
        location: LocationSample,
        source: String,
        query: String?,
        requestDetail: String
    ) async -> NativePlaceProbeResult {
        let startedAt = Date()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<([NativePlaceCandidate], Int), NativeSensorFailure>, Never>) in
            search.start { response, error in
                if let error {
                    let diagnostics = nativeNSErrorDiagnostics(prefix: "mapkit", error: error)
                    continuation.resume(
                        returning: .failure(
                            NativeSensorFailure(
                                reason: .missingSample,
                                reasonCode: diagnostics.reasonCode,
                                detail: "\(requestDetail);\(diagnostics.detail)"
                            )
                        )
                    )
                } else if let response {
                    let candidates = candidates(
                        from: response,
                        origin: location.clLocation,
                        source: source,
                        query: query,
                        locationAccuracyM: location.horizontalAccuracy
                    )
                    continuation.resume(returning: .success((candidates, response.mapItems.count)))
                } else {
                    continuation.resume(
                        returning: .failure(
                            NativeSensorFailure(
                                reason: .missingSample,
                                reasonCode: "mapkit_no_response",
                                detail: "\(requestDetail);MapKit returned no POI response."
                            )
                        )
                    )
                }
            }
        }
        let endedAt = Date()
        switch result {
        case .success(let success):
            let detail = [
                requestDetail,
                "result_count=\(success.1)",
                "usable_count=\(success.0.count)",
                "top_candidates=\(candidateTraceSummary(success.0))"
            ].joined(separator: ";")
            return NativePlaceProbeResult(
                candidates: success.0,
                trace: SensorStepTrace(
                    name: name,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    availability: success.0.isEmpty ? .unavailable : .available,
                    reasonCode: success.0.isEmpty ? "mapkit_no_usable_poi" : nil,
                    detail: detail
                )
            )
        case .failure(let failure):
            return NativePlaceProbeResult(
                candidates: [],
                trace: SensorStepTrace(
                    name: name,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    availability: .unavailable,
                    reasonCode: failure.reasonCode,
                    detail: failure.detail
                )
            )
        }
    }

    private static func candidates(
        from response: MKLocalSearch.Response,
        origin: CLLocation,
        source: String,
        query: String?,
        locationAccuracyM: Double
    ) -> [NativePlaceCandidate] {
        response.mapItems.enumerated().compactMap { index, item in
            guard let itemLocation = item.placemark.location else { return nil }
            let distance = itemLocation.distance(from: origin)
            guard distance <= 1_000 else { return nil }
            return candidate(
                category: item.pointOfInterestCategory,
                query: query,
                itemName: item.name,
                placemarkTitle: placemarkTitle(for: item.placemark),
                distance: distance,
                rank: index,
                source: source,
                locationAccuracyM: locationAccuracyM,
                latitude: itemLocation.coordinate.latitude,
                longitude: itemLocation.coordinate.longitude
            )
        }
        .sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.distanceM < rhs.distanceM }
            return lhs.confidence > rhs.confidence
        }
    }

    static func map(category: MKPointOfInterestCategory?, distance: CLLocationDistance, source: String = "mapkit_query_probe") -> NativeDerivedPlace {
        let candidate = candidate(
            category: category,
            query: nil,
            itemName: nil,
            placemarkTitle: nil,
            distance: distance,
            rank: 0,
            source: source,
            locationAccuracyM: 0,
            latitude: nil,
            longitude: nil
        )
        return NativeDerivedPlace(
            placeType: candidate.placeType,
            confidence: candidate.confidence,
            quality: quality(for: candidate.confidence),
            source: candidate.source,
            poiLookupAvailable: true
        )
    }

    static func testCandidate(
        category: MKPointOfInterestCategory?,
        query: String?,
        itemName: String?,
        distance: CLLocationDistance,
        rank: Int = 0,
        source: String = "mapkit_query_probe",
        locationAccuracyM: Double = 0
    ) -> NativePlaceCandidate {
        candidate(
            category: category,
            query: query,
            itemName: itemName,
            placemarkTitle: nil,
            distance: distance,
            rank: rank,
            source: source,
            locationAccuracyM: locationAccuracyM,
            latitude: nil,
            longitude: nil
        )
    }

    static func testDecision(candidates: [NativePlaceCandidate]) -> NativeDerivedPlace {
        decide(candidates: candidates).place
    }

    private static func candidate(
        category: MKPointOfInterestCategory?,
        query: String?,
        itemName: String?,
        placemarkTitle: String?,
        distance: CLLocationDistance,
        rank: Int,
        source: String,
        locationAccuracyM: Double,
        latitude: Double?,
        longitude: Double?
    ) -> NativePlaceCandidate {
        let itemText = [itemName, placemarkTitle]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let categoryPlaceType = category.flatMap(placeType(for:))
        let textPlaceType = placeType(forText: itemText)
        let queryPlaceType = placeType(forQuery: query)
        let placeType = categoryPlaceType ?? textPlaceType ?? queryPlaceType ?? "户外"
        let hasCategoryEvidence = categoryPlaceType != nil && categoryPlaceType != "户外"
        let hasTextEvidence = textPlaceType != nil && textPlaceType != "户外"
        let hasQueryEvidence = queryPlaceType != nil && queryPlaceType != "户外"
        let queryMatchesCategory = categoryPlaceType != nil && queryPlaceType != nil && categoryPlaceType == queryPlaceType
        let queryConflictsWithCategory = categoryPlaceType != nil && queryPlaceType != nil && categoryPlaceType != queryPlaceType

        var confidence = baseConfidence(forDistance: distance)
        if hasCategoryEvidence { confidence += 0.12 }
        if queryMatchesCategory { confidence += 0.08 }
        if hasTextEvidence { confidence += 0.06 }
        if rank == 0 { confidence += 0.04 } else if rank <= 2 { confidence += 0.02 }
        if queryConflictsWithCategory { confidence -= 0.10 }
        if locationAccuracyM > 100 { confidence -= 0.20 } else if locationAccuracyM > 50 { confidence -= 0.10 }

        let cap: Double
        if distance > 1_000 {
            cap = 0
        } else if hasCategoryEvidence {
            cap = 0.85
        } else if hasTextEvidence {
            cap = 0.60
        } else if hasQueryEvidence {
            cap = 0.45
        } else {
            cap = 0.15
        }
        confidence = min(max(confidence, 0), cap)

        let roundedDistance = Int(distance.rounded())
        let evidence = [
            "query=\(nativeDiagnosticValue(query ?? "none"))",
            "name=\(nativeDiagnosticValue(itemName ?? "none"))",
            "category=\(nativeDiagnosticValue(categoryRawValue(category)))",
            "distance_m=\(roundedDistance)",
            "rank=\(rank)",
            "category_match=\(queryMatchesCategory)",
            "category_conflict=\(queryConflictsWithCategory)"
        ].joined(separator: ",")
        let dedupeKey = makeDedupeKey(itemName: itemName, latitude: latitude, longitude: longitude, placeType: placeType)
        return NativePlaceCandidate(
            placeType: placeType,
            confidence: confidence,
            source: source,
            query: query,
            itemName: itemName,
            categoryRaw: categoryRawValue(category),
            distanceM: distance,
            rank: rank,
            evidence: evidence,
            dedupeKey: dedupeKey
        )
    }

    private static func placeType(for category: MKPointOfInterestCategory) -> String? {
        if category == .airport {
            return "机场"
        } else if category == .hotel {
            return "酒店"
        } else if category == .restaurant || category == .cafe || category == .bakery || category == .brewery || category == .foodMarket {
            return "餐厅"
        } else if category == .park || category == .nationalPark {
            return "公园"
        } else if category == .library {
            return "图书馆"
        } else if category == .store {
            return "商场"
        } else if category == .publicTransport {
            return "在途"
        } else if category == .beach || category == .marina {
            return "海边"
        } else if category == .school || category == .university {
            return "写字楼"
        }
        return nil
    }
    #endif

    private static func placeType(forQuery query: String?) -> String? {
        guard let query else { return nil }
        return placeType(forText: query)
    }

    private static func placeType(forText text: String) -> String? {
        let haystack = text.lowercased()
        if containsAny(haystack, ["机场", "airport"]) { return "机场" }
        if containsAny(haystack, ["酒店", "宾馆", "hotel"]) { return "酒店" }
        if containsAny(haystack, ["餐厅", "咖啡", "食堂", "饭店", "restaurant", "cafe"]) { return "餐厅" }
        if containsAny(haystack, ["公园", "park"]) { return "公园" }
        if containsAny(haystack, ["图书馆", "library"]) { return "图书馆" }
        if containsAny(haystack, ["商场", "商城", "广场", "购物", "mall", "store"]) { return "商场" }
        if containsAny(haystack, ["地铁", "车站", "火车站", "公交", "station", "transit"]) { return "在途" }
        if containsAny(haystack, ["海边", "码头", "beach", "marina"]) { return "海边" }
        if containsAny(haystack, ["学校", "大学", "学院", "研究院", "科技园", "园区", "大厦", "中心", "公司", "办公", "写字楼", "school", "university", "office"]) { return "写字楼" }
        return nil
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0.lowercased()) }
    }

    private static func baseConfidence(forDistance distance: Double) -> Double {
        if distance <= 50 { return 0.62 }
        if distance <= 100 { return 0.55 }
        if distance <= 200 { return 0.45 }
        if distance <= 500 { return 0.32 }
        if distance <= 1_000 { return 0.22 }
        return 0
    }

    private static func quality(for confidence: Double) -> String {
        confidence >= 0.65 ? "exact_or_good_mapping" : "noisy_mapping"
    }

    private static func decide(candidates rawCandidates: [NativePlaceCandidate]) -> NativePlaceDecision {
        let candidates = dedupeCandidates(rawCandidates).filter { $0.placeType != "户外" && $0.confidence > 0 }
        guard !candidates.isEmpty else {
            return NativePlaceDecision(
                place: fallbackPlace(),
                runnerUp: nil,
                margin: 0,
                candidateCount: 0,
                reasonCode: "place_fallback_outdoor"
            )
        }

        let groups = Dictionary(grouping: candidates, by: \.placeType)
        let scored = groups.map { placeType, grouped -> NativePlaceCandidate in
            let sorted = grouped.sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence { return lhs.distanceM < rhs.distanceM }
                return lhs.confidence > rhs.confidence
            }
            let top = sorted[0]
            let second = sorted.dropFirst().first?.confidence ?? 0
            let third = sorted.dropFirst(2).first?.confidence ?? 0
            let aggregate = min(0.85, top.confidence + 0.08 * second + 0.04 * third)
            return NativePlaceCandidate(
                placeType: placeType,
                confidence: aggregate,
                source: top.source,
                query: top.query,
                itemName: top.itemName,
                categoryRaw: top.categoryRaw,
                distanceM: top.distanceM,
                rank: top.rank,
                evidence: "aggregate_count=\(sorted.count);top=[\(top.evidence)]",
                dedupeKey: top.dedupeKey
            )
        }
        .sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.distanceM < rhs.distanceM }
            return lhs.confidence > rhs.confidence
        }

        guard let winner = scored.first else {
            return NativePlaceDecision(
                place: fallbackPlace(),
                runnerUp: nil,
                margin: 0,
                candidateCount: candidates.count,
                reasonCode: "place_fallback_outdoor"
            )
        }

        let runnerUp = scored.dropFirst().first
        let margin = winner.confidence - (runnerUp?.confidence ?? 0)
        var finalConfidence = winner.confidence
        let hasCloseRunnerUp = runnerUp.map { $0.confidence >= 0.35 && margin < 0.12 } ?? false
        if hasCloseRunnerUp {
            finalConfidence = max(0, finalConfidence - 0.10)
        }

        if margin < 0.05 && finalConfidence < 0.40 {
            return NativePlaceDecision(
                place: fallbackPlace(),
                runnerUp: runnerUp,
                margin: margin,
                candidateCount: candidates.count,
                reasonCode: "place_ambiguous_low_confidence"
            )
        }

        guard finalConfidence >= 0.40 else {
            return NativePlaceDecision(
                place: fallbackPlace(),
                runnerUp: runnerUp,
                margin: margin,
                candidateCount: candidates.count,
                reasonCode: "place_low_confidence"
            )
        }

        let source = winner.source == "mapkit_query_probe" && winner.query != nil
            ? "mapkit_query_probe:\(winner.query!)"
            : winner.source
        let place = NativeDerivedPlace(
            placeType: winner.placeType,
            confidence: finalConfidence,
            quality: hasCloseRunnerUp ? "noisy_mapping" : quality(for: finalConfidence),
            source: source,
            poiLookupAvailable: true
        )
        return NativePlaceDecision(
            place: place,
            runnerUp: runnerUp,
            margin: margin,
            candidateCount: candidates.count,
            reasonCode: nil
        )
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

    private static func makeDedupeKey(itemName: String?, latitude: Double?, longitude: Double?, placeType: String) -> String {
        let normalizedName = (itemName ?? "unknown")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let latitude, let longitude {
            return "\(normalizedName):\((latitude * 10_000).rounded() / 10_000):\((longitude * 10_000).rounded() / 10_000)"
        }
        return "\(normalizedName):\(placeType)"
    }

    private static func candidateTraceSummary(_ candidates: [NativePlaceCandidate]) -> String {
        let summary = candidates.prefix(3).map { candidate in
            [
                candidate.placeType,
                String(format: "%.2f", candidate.confidence),
                "d=\(Int(candidate.distanceM.rounded()))",
                "q=\(candidate.query ?? "none")",
                "name=\(nativeDiagnosticValue(candidate.itemName ?? "none"))",
                "cat=\(nativeDiagnosticValue(candidate.categoryRaw ?? "none"))"
            ].joined(separator: ",")
        }.joined(separator: "|")
        return summary.isEmpty ? "none" : summary
    }

    #if canImport(MapKit)
    private static func placemarkTitle(for placemark: MKPlacemark) -> String? {
        [placemark.name, placemark.title, placemark.thoroughfare, placemark.subThoroughfare, placemark.locality, placemark.subLocality]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private static func categoryRawValue(_ category: MKPointOfInterestCategory?) -> String {
        guard let category else { return "none" }
        return category.rawValue
    }
    #endif

    #if canImport(CoreLocation)
    private static func reverseGeocodeProbe(for location: LocationSample) async -> NativePlaceProbeResult {
        let startedAt = Date()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<String, NativeSensorFailure>, Never>) in
            CLGeocoder().reverseGeocodeLocation(location.clLocation) { placemarks, error in
                if let error {
                    let diagnostics = nativeNSErrorDiagnostics(prefix: "clgeocoder", error: error)
                    continuation.resume(
                        returning: .failure(
                            NativeSensorFailure(
                                reason: .missingSample,
                                reasonCode: diagnostics.reasonCode,
                                detail: diagnostics.detail
                            )
                        )
                    )
                } else if let placemark = placemarks?.first {
                    continuation.resume(returning: .success(reverseGeocodeSummary(for: placemark, count: placemarks?.count ?? 0)))
                } else {
                    continuation.resume(
                        returning: .failure(
                            NativeSensorFailure(
                                reason: .missingSample,
                                reasonCode: "clgeocoder_no_response",
                                detail: "CoreLocation reverse geocoder returned no placemark."
                            )
                        )
                    )
                }
            }
        }
        let endedAt = Date()
        switch result {
        case .success(let detail):
            return NativePlaceProbeResult(
                candidates: [],
                trace: SensorStepTrace(
                    name: "clgeocoder.reverse_geocode",
                    startedAt: startedAt,
                    endedAt: endedAt,
                    availability: .available,
                    detail: detail
                )
            )
        case .failure(let failure):
            return NativePlaceProbeResult(
                candidates: [],
                trace: SensorStepTrace(
                    name: "clgeocoder.reverse_geocode",
                    startedAt: startedAt,
                    endedAt: endedAt,
                    availability: .unavailable,
                    reasonCode: failure.reasonCode,
                    detail: failure.detail
                )
            )
        }
    }

    private static func reverseGeocodeSummary(for placemark: CLPlacemark, count: Int) -> String {
        var parts = ["placemark_count=\(count)"]
        if let name = placemark.name, !name.isEmpty { parts.append("name=\(nativeDiagnosticValue(name))") }
        if let locality = placemark.locality, !locality.isEmpty { parts.append("locality=\(nativeDiagnosticValue(locality))") }
        if let subLocality = placemark.subLocality, !subLocality.isEmpty { parts.append("subLocality=\(nativeDiagnosticValue(subLocality))") }
        if let inlandWater = placemark.inlandWater, !inlandWater.isEmpty { parts.append("inlandWater=\(nativeDiagnosticValue(inlandWater))") }
        if let ocean = placemark.ocean, !ocean.isEmpty { parts.append("ocean=\(nativeDiagnosticValue(ocean))") }
        if let areas = placemark.areasOfInterest, !areas.isEmpty {
            parts.append("areasOfInterest=\(areas.prefix(5).map(nativeDiagnosticValue).joined(separator: ","))")
        }
        return parts.joined(separator: ";")
    }
    #else
    private static func reverseGeocodeProbe(for location: LocationSample) async -> NativePlaceProbeResult {
        let now = Date()
        return NativePlaceProbeResult(
            candidates: [],
            trace: SensorStepTrace(
                name: "clgeocoder.reverse_geocode",
                startedAt: now,
                endedAt: now,
                availability: .unavailable,
                reasonCode: "clgeocoder_unsupported",
                detail: "CoreLocation reverse geocoder is unavailable in this build."
            )
        )
    }
    #endif

    private static func fallbackPlace() -> NativeDerivedPlace {
        NativeDerivedPlace(
            placeType: "户外",
            confidence: 0.15,
            quality: "noisy_mapping",
            source: "fallback_outdoor",
            poiLookupAvailable: false
        )
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
            name: "place.query_probe_decision",
            startedAt: now,
            endedAt: now,
            availability: place.poiLookupAvailable ? .available : .unavailable,
            reasonCode: decision.reasonCode,
            detail: [
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
