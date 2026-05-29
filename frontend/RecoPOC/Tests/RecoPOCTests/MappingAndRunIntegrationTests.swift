import XCTest
@testable import RecoPOC

final class MappingAndRunIntegrationTests: XCTestCase {
    func testVirtualContextDerivationAppliesLocationNoneAndPayloadSerializesLane1UserID() {
        let user = VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo")
            .first { $0.key == "u_no_location" }!
        let context = VirtualContextDeriver().derive(
            snapshot: .sampleFullPermission,
            virtualUser: user,
            questionnaire: .sample
        )
        let request = BackendPayloadMapper().recommendPayload(
            context: context,
            requestID: "run-001:u_no_location",
            topK: 3
        )

        XCTAssertEqual(request.userID, "device-demo:u_no_location")
        XCTAssertEqual(context.fields["place_type"], .string("任意"))
        XCTAssertEqual(context.fields["place_type_available"], .int(0))
        XCTAssertNil(context.fields["latitude"])
        XCTAssertNil(context.fields["longitude"])
        XCTAssertEqual(request.context["initial_need"], .string("学习/工作专注"))
    }

    func testApproximateLocationDowngradesPrecisionAndConfidence() {
        let user = VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo")
            .first { $0.key == "u_approx_location" }!
        let context = VirtualContextDeriver().derive(
            snapshot: .sampleFullPermission,
            virtualUser: user,
            questionnaire: .sample
        )

        XCTAssertEqual(context.fields["place_type_available"], .int(1))
        XCTAssertEqual(context.fields["place_type_confidence"], .double(0.25))
        XCTAssertEqual(context.fields["place_type_quality"], .string("noisy_mapping"))
        XCTAssertEqual(context.fields["location_accuracy_m"], .double(1000))
    }

    func testFeedbackPayloadUsesCorrectionTop1AcceptedSceneAndNoImpressionField() throws {
        let result = RecommendationResult(
            userID: "device-demo:u_full_permission",
            virtualUserKey: "u_full_permission",
            requestID: "run-001:u_full_permission",
            topScenes: ["专注", "阅读", "放松"],
            latencyMs: 42
        )
        let payload = try XCTUnwrap(BackendPayloadMapper().feedbackPayload(result: result, acceptedScene: RecoScene(id: 6, name: "阅读")))
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload.eventType, "correction")
        XCTAssertEqual(payload.recommendedScene, "专注")
        XCTAssertEqual(payload.acceptedScene, "阅读")
        XCTAssertNil(object["impression"])
        XCTAssertNil(object["dwell_time_sec"])
        XCTAssertNil(object["played_ratio_pct"])
        XCTAssertNil(object["next_action"])
    }

    func testRunCoordinatorUsesOneSnapshotForManyUsersAndSkipsFeedbackForFailedRecommendations() async {
        let users = Array(VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo").prefix(3))
        let failingKey = users[1].key
        let api = FakeRecommendationAPIClient(failFeedback: true, failedRecommendKeys: [failingKey])
        let queue = FeedbackRetryQueue(retryDelay: 10)
        let coordinator = RunCoordinator(
            sensorAcquirer: FakeRawSensorAcquirer(result: .success(.sampleFullPermission)),
            contextDeriver: VirtualContextDeriver(),
            payloadMapper: BackendPayloadMapper(),
            apiClient: api,
            feedbackQueue: queue,
            requestIDGenerator: TimestampRecommendationRequestIDGenerator()
        )

        let runState = await coordinator.runRecommendation(virtualUsers: users, questionnaire: .sample)
        XCTAssertEqual(runState.phase, .awaitingTrueScene)
        XCTAssertEqual(runState.contexts.count, users.count)
        XCTAssertEqual(runState.results.count, users.count)
        XCTAssertEqual(Set(runState.contexts.map { $0.fields["timestamp"] }), [.string("2026-05-28T16:40:00Z")])
        XCTAssertEqual(runState.results.filter(\.isSuccess).count, 2)

        let feedbackState = await coordinator.submitFeedback(selectedScene: RecoScene(id: 16, name: "冥想"), from: runState)
        XCTAssertEqual(feedbackState.phase, RunPhase.retryingFeedback)
        XCTAssertEqual(feedbackState.feedbackJobs.count, 2)
        XCTAssertEqual(feedbackState.retryQueueCount, 2)
        let queuedCount = queue.count
        XCTAssertEqual(queuedCount, 2)
        XCTAssertTrue(feedbackState.feedbackJobs.allSatisfy { $0.eventType == "correction" })
        XCTAssertFalse(feedbackState.feedbackJobs.contains { $0.userID == "device-demo:\(failingKey)" })
    }

    func testFreshFeedbackRetryQueueStartsEmptyAfterCoordinatorRecreation() async {
        let queue = FeedbackRetryQueue()
        let payload = FeedbackRequest(
            userID: "device-demo:u_full_permission",
            requestID: "run-001:u_full_permission",
            recommendedScene: "专注",
            acceptedScene: "阅读",
            eventType: "correction"
        )
        queue.enqueue(payload)
        let queuedCount = queue.count
        XCTAssertEqual(queuedCount, 1)

        let recreated = FeedbackRetryQueue()
        let recreatedCount = recreated.count
        XCTAssertEqual(recreatedCount, 0)
    }
}
