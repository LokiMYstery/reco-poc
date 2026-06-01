import Foundation
import XCTest
@testable import RecoPOC

final class PermissionCapabilityTests: XCTestCase {
    @MainActor
    func testSetupMaintenanceButtonInvokesProviderRequestAndShowsReturnedDetail() async throws {
        let provider = SpyPermissionCapabilityStatusProvider()
        var container = DependencyContainer.demo()
        container.permissionCapabilityStatusProvider = provider
        let model = DemoRecoPOCAppModel(
            container: container,
            deviceUUID: "device-test",
            setupPreferencesStore: MemorySetupPreferencesStore()
        )

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

    @MainActor
    func testSetupPreferencesPersistAcrossModelInstances() throws {
        let store = MemorySetupPreferencesStore()
        let firstModel = DemoRecoPOCAppModel(
            container: .demo(),
            deviceUUID: "device-test",
            setupPreferencesStore: store
        )

        firstModel.updateWillingness(for: "health", to: .wouldGrant)
        firstModel.updateWillingness(for: "microphone", to: .unsure)
        firstModel.setQuestionnaireSkipped(true)
        firstModel.setQuestionnaireSkipped(false)
        firstModel.setPrimaryIntent(InitialNeed.focus.rawValue)
        firstModel.toggleAdditionalNeed(InitialNeed.relax.rawValue)
        firstModel.setUserTag(UserTag.female.rawValue)

        let secondModel = DemoRecoPOCAppModel(
            container: .demo(),
            deviceUUID: "device-test",
            setupPreferencesStore: store
        )

        XCTAssertEqual(secondModel.setupScreen.permissions.first { $0.id == "health" }?.willingness, .wouldGrant)
        XCTAssertEqual(secondModel.setupScreen.permissions.first { $0.id == "microphone" }?.willingness, .unsure)
        XCTAssertFalse(secondModel.setupScreen.questionnaire.isSkipped)
        XCTAssertEqual(secondModel.setupScreen.questionnaire.primaryIntent, InitialNeed.focus.rawValue)
        XCTAssertEqual(secondModel.setupScreen.questionnaire.additionalNeeds, [InitialNeed.relax.rawValue])
        XCTAssertEqual(secondModel.setupScreen.questionnaire.userTag, UserTag.female.rawValue)
    }

    @MainActor
    func testHomeShowsHumanReadableSensorInputsAfterRun() async throws {
        let model = DemoRecoPOCAppModel(
            container: .demo(),
            deviceUUID: "device-test",
            setupPreferencesStore: MemorySetupPreferencesStore()
        )

        model.startRun()
        for _ in 0..<50 {
            if !model.homeScreen.sensorSnapshotRows.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let rows = model.homeScreen.sensorSnapshotRows
        XCTAssertTrue(rows.contains { $0.title == "Captured time" && $0.value.contains("2026") })
        XCTAssertTrue(rows.contains { $0.title == "Place" && $0.value == "写字楼" })
        XCTAssertTrue(rows.contains { $0.title == "Network" && $0.value == "wifi" })
        XCTAssertTrue(rows.contains { $0.title == "Audio route" && $0.value == "耳机" })
        XCTAssertTrue(rows.contains { $0.title == "Health" && $0.value.contains("steps/10m 250") })
        XCTAssertFalse(rows.map { "\($0.title) \($0.value) \($0.detail ?? "")" }.joined(separator: " ").contains("req_"))
    }
}

private final class MemorySetupPreferencesStore: SetupPreferencesStoring {
    var preferences: SetupPreferences?

    func loadSetupPreferences() -> SetupPreferences? {
        preferences
    }

    func saveSetupPreferences(_ preferences: SetupPreferences) {
        self.preferences = preferences
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
