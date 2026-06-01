import Foundation

enum HostConfiguration {
    static var backendBaseURL: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "RecoBackendBaseURL") as? String
        if let configured, !configured.isEmpty, let url = URL(string: configured) {
            return url
        }
        return URL(string: "http://127.0.0.1:8000")!
    }
}
