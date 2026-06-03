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
        XCTAssertNil(context.fields["place_candidates"])
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
        XCTAssertEqual(context.fields["place_candidates"], .array([
            .object([
                "place_type": .string("写字楼"),
                "confidence": .double(0.25),
                "distance_m": .double(32),
                "source": .string("amap_around_typecode_name"),
                "quality": .string("noisy_mapping")
            ])
        ]))
        XCTAssertEqual(context.fields["location_accuracy_m"], .double(1000))
    }

    func testFullLocationIncludesPlaceCandidatesAndCompatTop1Fields() {
        let user = VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo")
            .first { $0.key == "u_full_permission" }!
        let snapshot = RawSensorSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_000),
            timezone: "Asia/Shanghai",
            hour: 10,
            weekday: 2,
            network: "wifi",
            bluetooth: "耳机",
            placeType: "运动场所",
            placeTypeAvailable: true,
            placeTypeConfidence: 0.74,
            placeTypeQuality: "exact_or_good_mapping",
            placeCandidates: [
                PlaceCandidate(placeType: "运动场所", confidence: 0.74, distanceM: 32, source: "amap_around_typecode_name", quality: "exact_or_good_mapping"),
                PlaceCandidate(placeType: "餐厅", confidence: 0.61, distanceM: 48, source: "amap_around_typecode", quality: "noisy_mapping"),
            ],
            latitude: 31.2304,
            longitude: 121.4737,
            locationAccuracyM: 35,
            activityState: "静止",
            activityStateAvailable: true,
            heartRateAvailable: false
        )

        let context = VirtualContextDeriver().derive(
            snapshot: snapshot,
            virtualUser: user,
            questionnaire: .sample
        )

        XCTAssertEqual(context.fields["place_type"], .string("运动场所"))
        XCTAssertEqual(context.fields["place_type_available"], .int(1))
        XCTAssertEqual(context.fields["place_type_confidence"], .double(0.74))
        XCTAssertEqual(context.fields["place_type_quality"], .string("exact_or_good_mapping"))
        XCTAssertEqual(context.fields["place_candidates"], .array([
            .object([
                "place_type": .string("运动场所"),
                "confidence": .double(0.74),
                "distance_m": .double(32),
                "source": .string("amap_around_typecode_name"),
                "quality": .string("exact_or_good_mapping")
            ]),
            .object([
                "place_type": .string("餐厅"),
                "confidence": .double(0.61),
                "distance_m": .double(48),
                "source": .string("amap_around_typecode"),
                "quality": .string("noisy_mapping")
            ])
        ]))
    }

    func testPrivacyWeakSignalsUseKeywordWeatherAndOmitLightClass() {
        let snapshot = RawSensorSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_000),
            timezone: "Asia/Shanghai",
            hour: 10,
            weekday: 2,
            network: "wifi",
            bluetooth: "耳机",
            placeType: "任意",
            placeTypeAvailable: false,
            placeTypeConfidence: 0,
            placeTypeQuality: "unavailable",
            activityState: "任意",
            activityStateAvailable: false,
            heartRateAvailable: false,
            noiseClass: "普通",
            noiseAvailable: true,
            calendarKeyword: "会议",
            calendarAvailable: true,
            weather: "多云"
        )
        let user = VirtualUserRegistry.defaultUsers(deviceUUID: "device-demo")
            .first { $0.key == "u_full_permission" }!

        let context = VirtualContextDeriver().derive(
            snapshot: snapshot,
            virtualUser: user,
            questionnaire: .sample
        )

        XCTAssertEqual(context.fields["calendar_title"], .string("会议"))
        XCTAssertNil(context.fields["calendar_keyword"])
        XCTAssertEqual(context.fields["weather"], .string("多云"))
        XCTAssertEqual(context.fields["noise_class"], .string("普通"))
        XCTAssertNil(context.fields["light_class"])
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

    func testFeedbackPayloadIncludesOptionalQualityWhenPresent() throws {
        let result = RecommendationResult(
            userID: "device-demo:u_full_permission",
            virtualUserKey: "u_full_permission",
            requestID: "run-001:u_full_permission",
            topScenes: ["专注", "阅读", "放松"],
            latencyMs: 42
        )
        let quality = FeedbackQuality(dwellTimeSec: 19, playedRatioPct: 0.75, nextAction: "completed")
        let payload = try XCTUnwrap(BackendPayloadMapper().feedbackPayload(result: result, acceptedScene: RecoScene(id: 6, name: "阅读"), quality: quality))
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["dwell_time_sec"] as? Int, 19)
        XCTAssertEqual(object["played_ratio_pct"] as? Double, 0.75)
        XCTAssertEqual(object["next_action"] as? String, "completed")
        XCTAssertNil(object["impression"])
    }

    func testRunCoordinatorUsesOneSnapshotForManyUsersAndSubmitsFeedbackForEverySuccessfulResult() async {
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

        let feedbackState = await coordinator.submitFeedback(selectedScenes: [RecoScene(id: 16, name: "冥想")], from: runState)
        XCTAssertEqual(feedbackState.phase, RunPhase.retryingFeedback)
        XCTAssertEqual(feedbackState.feedbackJobs.count, 2)
        XCTAssertEqual(feedbackState.retryQueueCount, 2)
        let queuedCount = queue.count
        XCTAssertEqual(queuedCount, 2)
        XCTAssertTrue(feedbackState.feedbackJobs.allSatisfy { $0.eventType == "correction" })
        XCTAssertEqual(Set(feedbackState.feedbackJobs.map(\.userID)), Set(["device-demo:u_full_permission", "device-demo:u_no_location"]))
        XCTAssertFalse(feedbackState.feedbackJobs.contains { $0.userID == "device-demo:\(failingKey)" })
        XCTAssertNil(feedbackState.feedbackQuality?.dwellTimeSec)
        XCTAssertNil(feedbackState.feedbackQuality?.playedRatioPct)
        XCTAssertNil(feedbackState.feedbackQuality?.nextAction)
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
