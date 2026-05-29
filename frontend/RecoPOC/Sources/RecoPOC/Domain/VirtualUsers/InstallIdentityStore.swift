import Foundation

public protocol InstallIdentityStoring: Sendable {
    func stableDeviceUUID() -> String
}

public struct UserDefaultsInstallIdentityStore: InstallIdentityStoring, @unchecked Sendable {
    private let key: String
    private let defaults: UserDefaults
    private let generator: @Sendable () -> UUID

    public init(
        key: String = "reco_poc_install_device_uuid",
        defaults: UserDefaults = .standard,
        generator: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.key = key
        self.defaults = defaults
        self.generator = generator
    }

    public func stableDeviceUUID() -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }

        let created = generator().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }
}

public struct FixedInstallIdentityStore: InstallIdentityStoring {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public func stableDeviceUUID() -> String {
        value
    }
}
