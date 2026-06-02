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
    func testNewSetupDefaultsAllPermissionWillingnessToWouldGrant() {
        let model = DemoRecoPOCAppModel(
            container: .demo(),
            deviceUUID: "device-test",
            setupPreferencesStore: MemorySetupPreferencesStore()
        )

        XCTAssertTrue(model.setupScreen.permissions.allSatisfy { $0.willingness == .wouldGrant })
    }

    @MainActor
    func testRequestAllPermissionMaintenanceRequestsEveryOnboardingPermissionID() async throws {
        let provider = SpyPermissionCapabilityStatusProvider()
        var container = DependencyContainer.demo()
        container.permissionCapabilityStatusProvider = provider
        let model = DemoRecoPOCAppModel(
            container: container,
            deviceUUID: "device-test",
            setupPreferencesStore: MemorySetupPreferencesStore()
        )

        model.requestAllPermissionMaintenance()
        for _ in 0..<50 {
            if provider.requestedIDs == DemoRecoPOCAppModel.firstInstallPermissionRequestIDs { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(provider.requestedIDs, DemoRecoPOCAppModel.firstInstallPermissionRequestIDs)
    }

    @MainActor
    func testHomeShowsHumanReadableSensorInputsAfterRun() async throws {
        var snapshot = RawSensorSnapshot.sampleFullPermission
        snapshot.placeCandidates = [
            PlaceCandidate(
                placeType: "写字楼",
                confidence: 0.78,
                distanceM: 32,
                source: "amap_typecode_name",
                quality: "exact_or_good_mapping"
            ),
            PlaceCandidate(
                placeType: "餐厅",
                confidence: 0.61,
                distanceM: 48,
                source: "amap_typecode",
                quality: "noisy_mapping"
            ),
            PlaceCandidate(
                placeType: "运动场所",
                confidence: 0.52,
                distanceM: 76,
                source: "amap_name_keyword",
                quality: "noisy_mapping"
            )
        ]
        var container = DependencyContainer.demo()
        container.sensorAcquirer = FakeRawSensorAcquirer(result: .success(snapshot))
        let model = DemoRecoPOCAppModel(
            container: container,
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
        let placeRow = try XCTUnwrap(rows.first { $0.title == "Place" })
        XCTAssertEqual(placeRow.value, "写字楼 78% · 餐厅 61% · 运动场所 52%")
        XCTAssertTrue(placeRow.detail?.contains("#1 写字楼 78%, 32m, amap_typecode_name, exact_or_good_mapping") == true)
        XCTAssertTrue(placeRow.detail?.contains("#2 餐厅 61%, 48m, amap_typecode, noisy_mapping") == true)
        XCTAssertTrue(placeRow.detail?.contains("#3 运动场所 52%, 76m, amap_name_keyword, noisy_mapping") == true)
        XCTAssertTrue(rows.contains { $0.title == "Network" && $0.value == "wifi" })
        XCTAssertTrue(rows.contains { $0.title == "Audio route" && $0.value == "耳机" })
        XCTAssertTrue(rows.contains { $0.title == "Health" && $0.value.contains("steps/10m 250") })
        XCTAssertFalse(rows.map { "\($0.title) \($0.value) \($0.detail ?? "")" }.joined(separator: " ").contains("req_"))
    }

    @MainActor
    func testHomeShowsFullAccessResultAndSubmitsTrueScenesForAllSuccessfulVirtualUsers() async throws {
        let api = FakeRecommendationAPIClient()
        var container = DependencyContainer.demo()
        container.apiClient = api
        let model = DemoRecoPOCAppModel(
            container: container,
            deviceUUID: "device-test",
            setupPreferencesStore: MemorySetupPreferencesStore()
        )

        model.startRun()
        for _ in 0..<50 {
            if model.homeScreen.featuredResult != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.homeScreen.featuredResult?.userTitle, "u_full_permission")
        XCTAssertTrue(model.homeScreen.canSelectTrueScenes)

        model.toggleTrueSceneSelection("阅读")
        model.toggleTrueSceneSelection("冥想")
        model.toggleTrueSceneSelection("减压")
        model.toggleTrueSceneSelection("跑步")

        XCTAssertEqual(model.homeScreen.selectedScenes, ["阅读", "冥想", "减压"])
        XCTAssertTrue(model.homeScreen.canSubmitFeedback)

        let successfulUserIDs = Set(model.resultsScreen.groups.compactMap { group in
            group.errorMessage == nil ? "device-test:\(group.userTitle)" : nil
        })
        let expectedFeedbackCount = successfulUserIDs.count * model.homeScreen.selectedScenes.count

        model.submitFeedbackSelection()
        for _ in 0..<50 {
            if api.feedbackRequests.count == expectedFeedbackCount { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(api.feedbackRequests.count, expectedFeedbackCount)
        XCTAssertEqual(Set(api.feedbackRequests.map(\.acceptedScene)), Set(["阅读", "冥想", "减压"]))
        XCTAssertEqual(Set(api.feedbackRequests.map(\.userID)), successfulUserIDs)
        XCTAssertEqual(Set(api.feedbackRequests.map(\.requestID)).count, successfulUserIDs.count)
        XCTAssertTrue(api.feedbackRequests.allSatisfy { $0.eventType == "correction" })
        XCTAssertTrue(api.feedbackRequests.allSatisfy { $0.dwellTimeSec == nil && $0.playedRatioPct == nil && $0.nextAction == nil })
    }

    func testPermissionSetupCopyAvoidsAbstractHostTargetLanguage() {
        let gate = NativeCapablePermissionCapabilityStatusProvider().snapshot().gate
        let copy = [gate.title, gate.summary, gate.detail].joined(separator: " ")

        XCTAssertFalse(copy.contains("This host target owns"))
        XCTAssertTrue(copy.contains("Setup"))
        XCTAssertTrue(copy.contains("questionnaire"))
    }

    func testNativeNetworkMaintenanceWarmsConfiguredBackend() async throws {
        NetworkWarmupURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkWarmupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let url = try XCTUnwrap(URL(string: "https://experiment.test"))
        let provider = NativeCapablePermissionCapabilityStatusProvider(
            networkWarmupURL: url,
            networkSession: session
        )

        let status = await provider.requestMaintenance(for: "network")

        XCTAssertEqual(NetworkWarmupURLProtocol.requestedURLs, [url])
        XCTAssertEqual(NetworkWarmupURLProtocol.requestedMethods, ["HEAD"])
        XCTAssertEqual(status.id, "network")
        XCTAssertEqual(status.statusText, "Network warm-up completed")
        XCTAssertEqual(status.readiness, .available)
        XCTAssertTrue(status.detailText?.contains("HTTP 204") == true)
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

private final class NetworkWarmupURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequestedURLs: [URL] = []
    nonisolated(unsafe) private static var storedRequestedMethods: [String] = []

    static var requestedURLs: [URL] {
        lock.withLock { storedRequestedURLs }
    }

    static var requestedMethods: [String] {
        lock.withLock { storedRequestedMethods }
    }

    static func reset() {
        lock.withLock {
            storedRequestedURLs = []
            storedRequestedMethods = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let url = request.url {
            Self.lock.withLock {
                Self.storedRequestedURLs.append(url)
                Self.storedRequestedMethods.append(request.httpMethod ?? "GET")
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
