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

    func testSubmitFeedbackCreatesJobsOnlyForSuccessfulRecommendations() async {
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
        let runState = await coordinator.runRecommendation(virtualUsers: users, questionnaire: .sample)
        let selectedScene = SceneCatalog.all.first { $0.name == "阅读" }!
        let finalState = await coordinator.submitFeedback(selectedScene: selectedScene, from: runState)

        XCTAssertEqual(finalState.feedbackJobs.count, 1)
        XCTAssertEqual(api.feedbackRequests.count, 1)
        XCTAssertEqual(api.feedbackRequests.first?.eventType, "correction")
        XCTAssertEqual(api.feedbackRequests.first?.acceptedScene, "阅读")
        XCTAssertEqual(finalState.selectedTrueScene, "阅读")
        XCTAssertEqual(finalState.phase, RunPhase.completed)
        XCTAssertEqual(finalState.retryQueueCount, 0)
        XCTAssertTrue(finalState.timingEvents.map { $0.phase }.contains("true_scene_selected"))
        XCTAssertTrue(finalState.timingEvents.map { $0.phase }.contains("feedback_batch"))
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
