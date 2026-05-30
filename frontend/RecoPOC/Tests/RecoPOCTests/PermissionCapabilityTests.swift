import Foundation
import XCTest
@testable import RecoPOC

final class PermissionCapabilityTests: XCTestCase {
    @MainActor
    func testSetupMaintenanceButtonInvokesProviderRequestAndShowsReturnedDetail() async throws {
        let provider = SpyPermissionCapabilityStatusProvider()
        var container = DependencyContainer.demo()
        container.permissionCapabilityStatusProvider = provider
        let model = DemoRecoPOCAppModel(container: container, deviceUUID: "device-test")

        XCTAssertEqual(model.setupScreen.permissions.first { $0.id == "location" }?.systemStatus, "Ready for request")
        XCTAssertEqual(model.setupScreen.permissions.first { $0.id == "location" }?.systemDetail, "Initial snapshot detail")

        model.requestPermissionMaintenance(for: "location")
        XCTAssertEqual(model.setupScreen.permissions.first { $0.id == "location" }?.systemStatus, "Requesting test permission…")

        for _ in 0..<20 {
            if provider.requestedIDs == ["location"],
               model.setupScreen.permissions.first(where: { $0.id == "location" })?.systemStatus == "Authorized by test" {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(provider.requestedIDs, ["location"])
        let row = try XCTUnwrap(model.setupScreen.permissions.first { $0.id == "location" })
        XCTAssertEqual(row.systemStatus, "Authorized by test")
        XCTAssertEqual(row.systemDetail, "Provider requestMaintenance result was applied.")
    }
}

private final class SpyPermissionCapabilityStatusProvider: PermissionCapabilityStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequestedIDs: [String] = []

    var requestedIDs: [String] {
        lock.withLock { storedRequestedIDs }
    }

    func snapshot() -> PermissionCapabilityStatusSnapshot {
        PermissionCapabilityStatusSnapshot(
            gate: SetupCapabilityGateStatus(
                title: "Test native gate",
                summary: "Provider-backed setup flow",
                detail: "Used to verify setup calls requestMaintenance instead of only changing labels.",
                readiness: .available
            ),
            permissions: [
                PermissionCapabilityStatus(
                    id: "location",
                    statusText: "Ready for request",
                    detailText: "Initial snapshot detail",
                    readiness: .available
                )
            ]
        )
    }

    func maintenanceLabel(for permissionID: String) -> String {
        "Requesting test permission…"
    }

    func requestMaintenance(for permissionID: String) async -> PermissionCapabilityStatus {
        lock.withLock {
            storedRequestedIDs.append(permissionID)
        }
        return PermissionCapabilityStatus(
            id: permissionID,
            statusText: "Authorized by test",
            detailText: "Provider requestMaintenance result was applied.",
            readiness: .available
        )
    }
}
