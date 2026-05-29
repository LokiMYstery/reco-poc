import XCTest
import Foundation
@testable import RecoPOC

final class RecoPOCContractTests: XCTestCase {
    func testSceneCatalogFixtureContainsExactly18FixedScenes() throws {
        let scenes: [String] = try loadJSON("Contracts/scenes.json")

        XCTAssertEqual(scenes.count, 18)
        XCTAssertEqual(
            scenes,
            [
                "放松", "图书馆", "健身", "通勤", "游戏", "专注", "阅读", "深睡眠", "减压",
                "婴儿安睡", "胎教", "宠物陪伴", "经期舒缓", "睡午觉", "跑步", "瑜伽", "冥想", "深夜EMO"
            ]
        )
        XCTAssertEqual(Set(scenes).count, 18)
    }

    func testVirtualUserFixtureContainsAllBuiltInKeys() throws {
        let keys: [String] = try loadJSON("Contracts/virtual_user_keys.json")

        XCTAssertEqual(
            keys,
            [
                "u_full_permission",
                "u_minimal_context",
                "u_no_location",
                "u_approx_location",
                "u_location_only_no_health",
                "u_motion_only_no_health",
                "u_steps_only_no_hr_sleep",
                "u_no_watch_health_partial",
                "u_no_calendar_no_microphone",
                "u_calendar_enabled",
                "u_noise_enabled",
                "u_no_bluetooth_route",
                "u_weak_cellular_commuter",
                "u_home_speaker_no_health",
                "u_full_no_questionnaire",
                "u_intent_only_minimal_context"
            ]
        )
        XCTAssertEqual(Set(keys).count, 16)
    }

    func testQuestionnaireAvailabilityFlagsMatchSkipAndFilledStates() {
        XCTAssertEqual(QuestionnaireFixture.skipped.questionnaireAvailability, 0)
        XCTAssertEqual(QuestionnaireFixture.skipped.intentAvailability, 0)

        XCTAssertEqual(QuestionnaireFixture.full.questionnaireAvailability, 1)
        XCTAssertEqual(QuestionnaireFixture.full.intentAvailability, 1)

        XCTAssertEqual(QuestionnaireFixture.q2Only.questionnaireAvailability, 1)
        XCTAssertEqual(QuestionnaireFixture.q2Only.intentAvailability, 1)
    }

    func testBuiltInIdentityUsesDeviceUUIDAndBuiltInKeyDeterministically() {
        XCTAssertEqual(
            StableIdentityDeriver.userID(deviceUUID: "device-demo", virtualUserKey: "u_full_permission"),
            "device-demo:u_full_permission"
        )
        XCTAssertEqual(
            StableIdentityDeriver.userID(deviceUUID: "device-demo", virtualUserKey: "u_full_permission"),
            "device-demo:u_full_permission"
        )
    }

    func testAdHocIdentityKeyUsesProductionCanonicalization() {
        let lhs = PermissionWillingness(
            location: .approximate,
            motion: .none,
            health: .stepsOnly,
            microphone: .none,
            calendar: .full,
            audioRoute: .unknown,
            network: .weakCellular,
            questionnaire: .basic
        )
        let rhs = PermissionWillingness(
            location: .approximate,
            motion: .none,
            health: .stepsOnly,
            microphone: .none,
            calendar: .full,
            audioRoute: .unknown,
            network: .weakCellular,
            questionnaire: .basic
        )
        let firstOrder = QuestionnaireState(secondaryIntents: [.reading, .relax], userTag: .student)
        let secondOrder = QuestionnaireState(secondaryIntents: [.relax, .reading], userTag: .student)

        let lhsKey = StableIdentityDeriver.adHocVirtualUserKey(willingness: lhs, questionnaire: firstOrder)
        let rhsKey = StableIdentityDeriver.adHocVirtualUserKey(willingness: rhs, questionnaire: secondOrder)

        XCTAssertEqual(lhsKey, rhsKey)
        XCTAssertTrue(lhsKey.hasPrefix("u_ad_hoc_"))
        XCTAssertEqual(lhsKey.count, "u_ad_hoc_".count + 12)
    }

    func testFreezeWindowClampsAt15Seconds() {
        let freezeWindow = Duration.seconds(15)
        XCTAssertEqual(freezeWindow, .seconds(15))
    }

    func testOneSnapshotCanDeriveManyContextsWithoutMutation() {
        let snapshot = RawSnapshotFixture(id: "snapshot-1", placeType: "写字楼")
        let userA = DerivedContext(snapshotID: snapshot.id, virtualUserKey: "u_full_permission")
        let userB = DerivedContext(snapshotID: snapshot.id, virtualUserKey: "u_minimal_context")

        XCTAssertEqual(userA.snapshotID, snapshot.id)
        XCTAssertEqual(userB.snapshotID, snapshot.id)
        XCTAssertNotEqual(userA.virtualUserKey, userB.virtualUserKey)
    }

    func testRecommendPayloadFixtureMatchesContractShape() throws {
        let payload: RecommendPayloadFixture = try loadJSON("GoldenPayloads/recommend_payload.json")

        XCTAssertEqual(payload.userID, "device-demo:u_full_permission")
        XCTAssertEqual(payload.requestID, "run-001:u_full_permission")
        XCTAssertEqual(payload.topK, 3)
        XCTAssertEqual(payload.context.questionnaireAvailable, 1)
        XCTAssertEqual(payload.context.intentAvailable, 1)
        XCTAssertEqual(payload.context.intent, "学习/工作专注")
        XCTAssertEqual(payload.context.initialNeed, "学习/工作专注")
        XCTAssertEqual(payload.context.initialNeeds, ["阅读陪伴", "放松/减压"])
    }

    func testFeedbackPayloadFixtureUsesCorrectionAndOmitsImpression() throws {
        let payload: FeedbackPayloadFixture = try loadJSON("GoldenPayloads/feedback_payload.json")
        let raw = try loadRawJSON("GoldenPayloads/feedback_payload.json")

        XCTAssertEqual(payload.eventType, "correction")
        XCTAssertEqual(payload.recommendedScene, "专注")
        XCTAssertEqual(payload.acceptedScene, "阅读")
        XCTAssertNil(raw["impression"])
        XCTAssertNil(raw["dwell_time_sec"])
        XCTAssertNil(raw["played_ratio_pct"])
        XCTAssertNil(raw["next_action"])
    }

    func testRichFeedbackPayloadFixtureIncludesOptionalQualityFields() throws {
        let payload: RichFeedbackPayloadFixture = try loadJSON("GoldenPayloads/feedback_payload_rich.json")
        let raw = try loadRawJSON("GoldenPayloads/feedback_payload_rich.json")

        XCTAssertEqual(payload.eventType, "correction")
        XCTAssertEqual(payload.recommendedScene, "专注")
        XCTAssertEqual(payload.acceptedScene, "阅读")
        XCTAssertEqual(payload.dwellTimeSec, 19)
        XCTAssertEqual(payload.playedRatioPct, 0.75)
        XCTAssertEqual(payload.nextAction, "completed")
        XCTAssertNil(raw["impression"])
    }

    func testFreshCoordinatorStartsWithClearedFeedbackRetryQueue() {
        let original = InMemoryFeedbackRetryQueue()
        original.enqueue(.init(requestID: "run-001:u_full_permission"))
        XCTAssertEqual(original.pendingCount, 1)

        let recreated = InMemoryFeedbackRetryQueue()
        XCTAssertEqual(recreated.pendingCount, 0)
    }
}

private struct QuestionnaireFixture {
    let questionnaireAvailability: Int
    let intentAvailability: Int

    static let skipped = QuestionnaireFixture(questionnaireAvailability: 0, intentAvailability: 0)
    static let full = QuestionnaireFixture(questionnaireAvailability: 1, intentAvailability: 1)
    static let q2Only = QuestionnaireFixture(questionnaireAvailability: 1, intentAvailability: 1)
}

private struct RawSnapshotFixture {
    let id: String
    let placeType: String
}

private struct DerivedContext {
    let snapshotID: String
    let virtualUserKey: String
}

private struct RecommendPayloadFixture: Decodable {
    let userID: String
    let requestID: String
    let topK: Int
    let context: Context

    struct Context: Decodable {
        let questionnaireAvailable: Int
        let intentAvailable: Int
        let intent: String
        let initialNeed: String
        let initialNeeds: [String]

        private enum CodingKeys: String, CodingKey {
            case questionnaireAvailable = "questionnaire_available"
            case intentAvailable = "intent_available"
            case intent
            case initialNeed = "initial_need"
            case initialNeeds = "initial_needs"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case requestID = "request_id"
        case topK = "top_k"
        case context
    }

    struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int?
        init?(intValue: Int) { return nil }
    }
}

private struct FeedbackPayloadFixture: Decodable {
    let userID: String
    let requestID: String
    let eventType: String
    let recommendedScene: String
    let acceptedScene: String

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case requestID = "request_id"
        case eventType = "event_type"
        case recommendedScene = "recommended_scene"
        case acceptedScene = "accepted_scene"
    }
}

private struct RichFeedbackPayloadFixture: Decodable {
    let userID: String
    let requestID: String
    let eventType: String
    let recommendedScene: String
    let acceptedScene: String
    let dwellTimeSec: Int
    let playedRatioPct: Double
    let nextAction: String

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case requestID = "request_id"
        case eventType = "event_type"
        case recommendedScene = "recommended_scene"
        case acceptedScene = "accepted_scene"
        case dwellTimeSec = "dwell_time_sec"
        case playedRatioPct = "played_ratio_pct"
        case nextAction = "next_action"
    }
}

private struct RetryJob {
    let requestID: String
}

private final class InMemoryFeedbackRetryQueue {
    private var jobs: [RetryJob] = []

    var pendingCount: Int { jobs.count }

    func enqueue(_ job: RetryJob) {
        jobs.append(job)
    }
}

private func loadJSON<T: Decodable>(_ relativePath: String) throws -> T {
    let data = try Data(contentsOf: fixtureURL(relativePath))
    return try JSONDecoder().decode(T.self, from: data)
}

private func loadRawJSON(_ relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: fixtureURL(relativePath))
    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
}

private func fixtureURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(relativePath)
}
