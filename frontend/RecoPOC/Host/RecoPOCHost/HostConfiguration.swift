import Foundation
import RecoPOC

enum HostConfiguration {
    static var backendBaseURL: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "RecoBackendBaseURL") as? String
        if let configured, !configured.isEmpty, let url = URL(string: configured) {
            return url
        }
        return URL(string: "http://127.0.0.1:8000")!
    }

    static var amapConfiguration: AmapPOIConfiguration {
        AmapPOIConfiguration(
            apiKey: stringValue(for: "RecoAmapAPIKey") ?? "",
            enabled: boolValue(for: "RecoAmapPOIEnabled"),
            inputCoordinateSystem: inputCoordinateSystem,
            radiusM: doubleValue(for: "RecoAmapPOIRadiusM") ?? 500
        )
    }

    private static var inputCoordinateSystem: AmapInputCoordinateSystem {
        let raw = stringValue(for: "RecoAmapInputCoordSys")?.lowercased()
        return AmapInputCoordinateSystem(rawValue: raw ?? "") ?? .gps
    }

    private static func stringValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolValue(for key: String) -> Bool {
        switch Bundle.main.object(forInfoDictionaryKey: key) {
        case let value as Bool:
            return value
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "enabled"].contains(normalized)
        default:
            return false
        }
    }

    private static func doubleValue(for key: String) -> Double? {
        switch Bundle.main.object(forInfoDictionaryKey: key) {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
