import Foundation

#if canImport(Network)
import Network
#endif

#if canImport(CoreLocation)
import CoreLocation
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

public struct NativeSensorProviderCatalog {
    public init() {}

    public func makeProviders() -> [any RawSensorReadingProvider] {
        [
            TimeSensorProvider(),
            LocationSensorProvider(),
            BatterySensorProvider(),
            ConnectivitySensorProvider(),
            HeadingSensorProvider(),
            ActivitySensorProvider(),
            MotionSensorProvider(),
            HealthSensorProvider(),
            MicrophoneSensorProvider(),
            CalendarSensorProvider(),
            WeatherSensorProvider()
        ]
    }
}

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

public struct LocationSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .location
    private let provider: any LocationSnapshotProviding

    public init(provider: any LocationSnapshotProviding = SystemLocationSnapshotProvider()) {
        self.provider = provider
    }

    public func read() async -> RawSensorProviderResult {
        await provider.readLocationSnapshot()
    }
}

public protocol LocationSnapshotProviding: Sendable {
    func readLocationSnapshot() async -> RawSensorProviderResult
}

public struct SystemLocationSnapshotProvider: LocationSnapshotProviding {
    public init() {}

    public func readLocationSnapshot() async -> RawSensorProviderResult {
        #if canImport(CoreLocation)
        guard CLLocationManager.locationServicesEnabled() else {
            return .unavailable(.sensorDisabled)
        }

        let authorizationStatus: CLAuthorizationStatus
        if #available(iOS 14.0, macOS 11.0, *) {
            authorizationStatus = CLLocationManager().authorizationStatus
        } else {
            authorizationStatus = CLLocationManager.authorizationStatus()
        }

        switch authorizationStatus {
        case .denied, .restricted:
            return .unavailable(.permissionDenied)
        case .notDetermined:
            return .unavailable(.missingSample)
        case .authorizedAlways, .authorizedWhenInUse:
            return .unavailable(.missingSample)
        @unknown default:
            return .unavailable(.unsupported)
        }
        #else
        return .unavailable(.unsupported)
        #endif
    }
}

public struct BatterySensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .battery
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}

public struct ConnectivitySensorProvider: RawSensorReadingProvider {
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
        let observedAt = Date()
        let route = await routeProvider.currentRouteLabel()
        var values: [String: JSONValue] = ["bluetooth": .string(route)]

        if let pathSnapshot = await pathProvider.currentPathSnapshot() {
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

        return .reading(RawSensorReading(observedAt: observedAt, freshnessWindow: 30, values: values))
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
            let path = NWPathMonitor().currentPath
            return NetworkPathSnapshot(
                networkLabel: Self.networkLabel(for: path),
                statusLabel: Self.statusLabel(for: path.status),
                isExpensive: path.isExpensive,
                isConstrained: Self.isConstrained(path)
            )
        }
        #endif
        return nil
    }

    #if canImport(Network)
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

public struct ActivitySensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .activity
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}

public struct MotionSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .motion
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}

public struct HealthSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .health
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}

public struct MicrophoneSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .microphone
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}

public struct CalendarSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .calendar
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}


public struct WeatherSensorProvider: RawSensorReadingProvider {
    public let sensorName: RawSensorName = .weather
    public init() {}
    public func read() async -> RawSensorProviderResult { .unavailable(.unsupported) }
}
