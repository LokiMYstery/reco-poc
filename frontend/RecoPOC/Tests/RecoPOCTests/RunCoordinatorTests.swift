import XCTest
@testable import RecoPOC

final class RunCoordinatorTests: XCTestCase {
    func testRunRecommendationUsesPhaseOrderAndOneRequestPerVirtualUser() async {
        let api = FakeRecommendationAPIClient(failedRecommendKeys: ["u_no_location"])
        let queue = FeedbackRetryQueue(retryDelay: 1)
        let coordinator = RunCoordinator(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: api,
            feedbackQueue: queue,
            requestIDGenerator: TimestampRecommendationRequestIDGenerator()
        )

        let builtIns = VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo")
        let users = [builtIns[0], builtIns[2]]
        let state = await coordinator.runRecommendation(virtualUsers: users, questionnaire: .sample)
        let phases = state.timingEvents.map { $0.phase }

        XCTAssertEqual(state.phase, RunPhase.awaitingTrueScene)
        XCTAssertEqual(state.contexts.count, 2)
        XCTAssertEqual(state.results.count, 2)
        XCTAssertEqual(api.recommendRequests.count, 2)
        XCTAssertEqual(Set(api.recommendRequests.map { $0.userID }), Set(users.map { $0.userID }))
        XCTAssertEqual(state.results.filter { $0.isSuccess }.count, 1)
        XCTAssertEqual(state.results.filter { !$0.isSuccess }.count, 1)
        XCTAssertEqual(phases.first, "acquisition")
        XCTAssertTrue(phases.contains("derive"))
        XCTAssertTrue(phases.contains("recommend_\(users[0].key)"))
        XCTAssertTrue(phases.contains("recommend_\(users[1].key)"))
        XCTAssertEqual(phases.last, "results")
    }

    func testSubmitFeedbackCreatesJobForEverySuccessfulRecommendation() async {
        let api = FakeRecommendationAPIClient(failedRecommendKeys: ["u_no_location"])
        let queue = FeedbackRetryQueue(retryDelay: 1)
        let coordinator = RunCoordinator(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: api,
            feedbackQueue: queue,
            requestIDGenerator: TimestampRecommendationRequestIDGenerator()
        )

        let builtIns = VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo")
        let users = [builtIns[0], builtIns[1], builtIns[2]]
        let runState = await coordinator.runRecommendation(virtualUsers: users, questionnaire: .sample)
        let selectedScene = SceneCatalog.all.first { $0.name == "阅读" }!
        let finalState = await coordinator.submitFeedback(selectedScene: selectedScene, from: runState)

        XCTAssertEqual(finalState.feedbackJobs.count, 2)
        XCTAssertEqual(api.feedbackRequests.count, 2)
        XCTAssertEqual(Set(api.feedbackRequests.map(\.userID)), Set(["device-demo:u_full_permission", "device-demo:u_minimal_context"]))
        XCTAssertFalse(api.feedbackRequests.contains { $0.userID == "device-demo:u_no_location" })
        XCTAssertTrue(api.feedbackRequests.allSatisfy { $0.eventType == "correction" })
        XCTAssertTrue(api.feedbackRequests.allSatisfy { $0.acceptedScene == "阅读" })
        XCTAssertTrue(api.feedbackRequests.allSatisfy { $0.dwellTimeSec == nil && $0.playedRatioPct == nil && $0.nextAction == nil })
        XCTAssertEqual(finalState.selectedTrueScene, "阅读")
        XCTAssertEqual(finalState.selectedTrueScenes, ["阅读"])
        XCTAssertEqual(finalState.phase, RunPhase.completed)
        XCTAssertEqual(finalState.retryQueueCount, 0)
        XCTAssertTrue(finalState.timingEvents.map { $0.phase }.contains("true_scenes_selected"))
        XCTAssertTrue(finalState.timingEvents.map { $0.phase }.contains("feedback_batch"))
    }

    func testSubmitFeedbackCapsThreeScenesPerSuccessfulRecommendation() async {
        let api = FakeRecommendationAPIClient()
        let queue = FeedbackRetryQueue(retryDelay: 1)
        let coordinator = RunCoordinator(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: api,
            feedbackQueue: queue,
            requestIDGenerator: TimestampRecommendationRequestIDGenerator()
        )

        let users = Array(VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo").prefix(2))
        let runState = await coordinator.runRecommendation(virtualUsers: users, questionnaire: .sample)
        let scenes = ["阅读", "冥想", "减压", "跑步"].compactMap(SceneCatalog.scene(named:))
        let finalState = await coordinator.submitFeedback(selectedScenes: scenes, from: runState)

        XCTAssertEqual(api.feedbackRequests.count, 6)
        XCTAssertEqual(Set(api.feedbackRequests.map(\.userID)), Set(["device-demo:u_full_permission", "device-demo:u_minimal_context"]))
        XCTAssertEqual(Set(api.feedbackRequests.map(\.requestID)), Set(["req_u_full_permission_1779986400", "req_u_minimal_context_1779986400"]))
        for userID in Set(api.feedbackRequests.map(\.userID)) {
            XCTAssertEqual(api.feedbackRequests.filter { $0.userID == userID }.map(\.acceptedScene), ["阅读", "冥想", "减压"])
        }
        XCTAssertTrue(api.feedbackRequests.allSatisfy { $0.eventType == "correction" })
        XCTAssertTrue(api.feedbackRequests.allSatisfy { $0.dwellTimeSec == nil && $0.playedRatioPct == nil && $0.nextAction == nil })
        XCTAssertEqual(finalState.selectedTrueScenes, ["阅读", "冥想", "减压"])
    }

    func testSubmitFeedbackForSpecificVirtualUserKeepsSingleResultScope() async {
        let api = FakeRecommendationAPIClient()
        let queue = FeedbackRetryQueue(retryDelay: 1)
        let coordinator = RunCoordinator(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: api,
            feedbackQueue: queue,
            requestIDGenerator: TimestampRecommendationRequestIDGenerator()
        )

        let users = Array(VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo").prefix(2))
        let runState = await coordinator.runRecommendation(virtualUsers: users, questionnaire: .sample)
        let scenes = ["阅读", "冥想", "减压", "跑步"].compactMap(SceneCatalog.scene(named:))
        let finalState = await coordinator.submitFeedback(selectedScenes: scenes, from: runState, forVirtualUserKey: "u_full_permission")

        XCTAssertEqual(api.feedbackRequests.count, 3)
        XCTAssertEqual(api.feedbackRequests.map(\.acceptedScene), ["阅读", "冥想", "减压"])
        XCTAssertEqual(Set(api.feedbackRequests.map(\.userID)), Set(["device-demo:u_full_permission"]))
        XCTAssertEqual(Set(api.feedbackRequests.map(\.requestID)), Set(["req_u_full_permission_1779986400"]))
        XCTAssertEqual(finalState.feedbackJobs.count, 3)
    }

    func testSubmitFeedbackPreservesSelectedOptionalQualityValues() async {
        let api = FakeRecommendationAPIClient()
        let queue = FeedbackRetryQueue(retryDelay: 1)
        let coordinator = RunCoordinator(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: api,
            feedbackQueue: queue,
            requestIDGenerator: TimestampRecommendationRequestIDGenerator()
        )

        let user = VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo")[0]
        let runState = await coordinator.runRecommendation(virtualUsers: [user], questionnaire: .sample)
        let selectedScene = SceneCatalog.all.first { $0.name == "阅读" }!
        let quality = FeedbackQuality(dwellTimeSec: 19, playedRatioPct: 0.75, nextAction: "completed")
        let finalState = await coordinator.submitFeedback(selectedScene: selectedScene, from: runState, quality: quality)

        XCTAssertEqual(api.feedbackRequests.count, 1)
        XCTAssertEqual(api.feedbackRequests.first?.playedRatioPct, 0.75)
        XCTAssertEqual(api.feedbackRequests.first?.nextAction, "completed")
        XCTAssertEqual(api.feedbackRequests.first?.dwellTimeSec, 19)
        XCTAssertEqual(finalState.feedbackQuality?.dwellTimeSec, 19)
        XCTAssertEqual(finalState.feedbackQuality?.playedRatioPct, 0.75)
        XCTAssertEqual(finalState.feedbackQuality?.nextAction, "completed")
    }

    func testFeedbackFailureEnqueuesRetryCountdownAndFreshCoordinatorClearsQueue() async {
        let requestIDGen = TimestampRecommendationRequestIDGenerator()
        let failingAPI = FakeRecommendationAPIClient(transientFeedbackFailuresByRequestID: ["req_u_full_permission_1779986400": 1])
        let queue = FeedbackRetryQueue(retryDelay: 1)
        let coordinator = RunCoordinator(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: failingAPI,
            feedbackQueue: queue,
            requestIDGenerator: requestIDGen
        )

        let user = VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo")[0]
        let runState = await coordinator.runRecommendation(virtualUsers: [user], questionnaire: .sample)
        let selectedScene = SceneCatalog.all.first { $0.name == "阅读" }!
        let feedbackState = await coordinator.submitFeedback(selectedScene: selectedScene, from: runState)

        XCTAssertEqual(feedbackState.phase, RunPhase.retryingFeedback)
        XCTAssertEqual(feedbackState.retryQueueCount, 1)
        XCTAssertEqual(feedbackState.retryJobs.first?.request.requestID, "req_u_full_permission_1779986400")
        XCTAssertEqual(feedbackState.retryJobs.first?.attempt, 1)
        XCTAssertGreaterThanOrEqual(feedbackState.retryJobs.first?.secondsRemaining ?? -1, 0)

        try? await Task.sleep(nanoseconds: 1_300_000_000)
        let jobsAfterRetry = await coordinator.currentRetryJobs()
        XCTAssertTrue(jobsAfterRetry.isEmpty)
        XCTAssertEqual(failingAPI.feedbackAttempts["req_u_full_permission_1779986400"], 2)

        let freshQueue = FeedbackRetryQueue(retryDelay: 1)
        let freshCoordinator = RunCoordinator(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: FakeRecommendationAPIClient(),
            feedbackQueue: freshQueue,
            requestIDGenerator: requestIDGen
        )
        _ = await freshCoordinator.runRecommendation(virtualUsers: [user], questionnaire: .sample)
        XCTAssertEqual(freshQueue.count, 0)
    }

    func testStartingAnotherRunPreservesInMemoryFeedbackQueueDuringSameProcess() async {
        let api = FakeRecommendationAPIClient(failFeedback: true)
        let queue = FeedbackRetryQueue(retryDelay: 60)
        let coordinator = RunCoordinator(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: api,
            feedbackQueue: queue,
            requestIDGenerator: TimestampRecommendationRequestIDGenerator()
        )

        let user = VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo")[0]
        let firstRun = await coordinator.runRecommendation(virtualUsers: [user], questionnaire: .sample)
        let feedbackState = await coordinator.submitFeedback(selectedScene: RecoScene(id: 6, name: "阅读"), from: firstRun)

        XCTAssertEqual(feedbackState.retryQueueCount, 1)
        XCTAssertEqual(queue.count, 1)

        _ = await coordinator.runRecommendation(virtualUsers: [user], questionnaire: .sample)

        XCTAssertEqual(queue.count, 1)
        let jobs = await coordinator.currentRetryJobs()
        XCTAssertEqual(jobs.count, 1)
    }
}
