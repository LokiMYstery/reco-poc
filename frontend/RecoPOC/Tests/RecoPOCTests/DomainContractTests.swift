import XCTest
@testable import RecoPOC

final class DomainContractTests: XCTestCase {
    func testSceneCatalogMatchesFixed18Scenes() {
        XCTAssertEqual(SceneCatalog.all.count, 18)
        XCTAssertEqual(
            SceneCatalog.names,
            ["放松", "图书馆", "健身", "通勤", "游戏", "专注", "阅读", "深睡眠", "减压", "婴儿安睡", "胎教", "宠物陪伴", "经期舒缓", "睡午觉", "跑步", "瑜伽", "冥想", "深夜EMO"]
        )
        XCTAssertEqual(SceneCatalog.all.map(\.id), Array(0...17))
    }

    func testVirtualUserRegistryContainsAll16BuiltInsInStableOrder() {
        XCTAssertEqual(
            VirtualUserRegistry.builtInKeys,
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
    }

    func testBuiltInUserIDUsesDeviceUUIDPlusColonPlusVirtualUserKey() {
        XCTAssertEqual(
            StableIdentityDeriver.userID(deviceUUID: "device-123", virtualUserKey: "u_full_permission"),
            "device-123:u_full_permission"
        )
    }

    func testQuestionnaireMappingForSkippedQuestionnaire() {
        let state = QuestionnaireState.skipped
        XCTAssertFalse(state.questionnaireAvailable)
        XCTAssertFalse(state.intentAvailable)
        XCTAssertNil(state.initialNeed)
    }

    func testQuestionnaireMappingForTagOnlyQuestionnaire() {
        let state = QuestionnaireState(userTag: .student)
        XCTAssertTrue(state.questionnaireAvailable)
        XCTAssertFalse(state.intentAvailable)
        XCTAssertNil(state.initialNeed)
        XCTAssertEqual(state.contextFields()["user_tag"], .string("学生"))
    }

    func testTagOnlyQuestionnaireAnnotationUsesBasicMaskAndPreservesAvailability() {
        let questionnaire = QuestionnaireState(userTag: .student)
        let annotations = PermissionWillingnessAnnotations(
            location: .wouldGrant,
            motion: .wouldGrant,
            health: .wouldGrant,
            microphone: .wouldNotGrant,
            calendar: .wouldNotGrant,
            isQuestionnaireSkipped: false,
            questionnaire: questionnaire
        )

        XCTAssertEqual(annotations.willingness.questionnaire, .basic)

        let user = VirtualUser(
            key: "tag-only",
            displayName: "Tag only",
            purpose: "test",
            mask: annotations.willingness.asMask,
            userID: "device:tag-only"
        )
        let context = VirtualContextDeriver().derive(snapshot: .sampleFullPermission, virtualUser: user, questionnaire: questionnaire)

        XCTAssertEqual(context.fields["questionnaire_available"], .int(1))
        XCTAssertEqual(context.fields["intent_available"], .int(0))
        XCTAssertEqual(context.fields["user_tag"], .string("学生"))
        XCTAssertNil(context.fields["initial_need"])
    }

    func testQuestionnaireMappingForQ2OnlyQuestionnaireUsesFirstAdditionalAsInitialNeed() {
        let state = QuestionnaireState(secondaryIntents: [.sleep, .relax])
        XCTAssertTrue(state.questionnaireAvailable)
        XCTAssertTrue(state.intentAvailable)
        XCTAssertEqual(state.initialNeed, .sleep)
        XCTAssertEqual(state.contextFields()["initial_need"], .string("睡眠/午休"))
    }

    func testQuestionnaireMappingForFullQuestionnairePreservesPrimaryIntent() {
        let state = QuestionnaireState(
            primaryIntent: .focus,
            secondaryIntents: [.relax, .reading],
            userTag: .any,
            gender: .undisclosed
        )
        XCTAssertTrue(state.questionnaireAvailable)
        XCTAssertTrue(state.intentAvailable)
        XCTAssertEqual(state.initialNeed, .focus)
        XCTAssertEqual(state.contextFields()["initial_needs"], .array([.string("放松/减压"), .string("阅读陪伴")]))
    }

    func testCanonicalPatternJSONIsStableAndSorted() {
        let willingness = PermissionWillingness(
            location: .approximate,
            motion: .none,
            health: .none,
            microphone: .none,
            calendar: .full,
            audioRoute: .unknown,
            network: .weakCellular,
            questionnaire: .basic
        )
        let questionnaire = QuestionnaireState(secondaryIntents: [.sleep, .relax], userTag: .student)
        XCTAssertEqual(
            StableIdentityDeriver.canonicalRepresentation(willingness: willingness, questionnaire: questionnaire),
            "{\"audio_route\":\"unknown\",\"calendar\":\"full\",\"gender\":null,\"health\":\"none\",\"initial_need\":\"放松/减压\",\"initial_needs\":[\"放松/减压\",\"睡眠/午休\"],\"intent_available\":true,\"location\":\"approximate\",\"microphone\":\"none\",\"motion\":\"none\",\"network\":\"weak_cellular\",\"questionnaire\":\"basic\",\"questionnaire_available\":true,\"user_tag\":\"学生\"}"
        )
    }

    func testAdHocVirtualUserKeyIsDeterministicAndLowercaseHexPrefixed() {
        let willingness = PermissionWillingness(
            location: .approximate,
            motion: .none,
            health: .none,
            microphone: .none,
            calendar: .full,
            audioRoute: .unknown,
            network: .weakCellular,
            questionnaire: .basic
        )
        let questionnaire = QuestionnaireState(secondaryIntents: [.sleep, .relax], userTag: .student)
        let keyA = StableIdentityDeriver.adHocVirtualUserKey(willingness: willingness, questionnaire: questionnaire)
        let keyB = StableIdentityDeriver.adHocVirtualUserKey(willingness: willingness, questionnaire: questionnaire)
        XCTAssertEqual(keyA, keyB)
        XCTAssertTrue(keyA.hasPrefix("u_ad_hoc_"))
        XCTAssertEqual(keyA.count, "u_ad_hoc_".count + 12)
        XCTAssertTrue(keyA.dropFirst("u_ad_hoc_".count).allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testAdHocUserIDUsesDerivedAdHocKey() {
        let willingness = PermissionWillingness(
            location: .full,
            motion: .full,
            health: .noWatch,
            microphone: .none,
            calendar: .none,
            questionnaire: .full
        )
        let questionnaire = QuestionnaireState(primaryIntent: .commute)
        let key = StableIdentityDeriver.adHocVirtualUserKey(willingness: willingness, questionnaire: questionnaire)
        XCTAssertEqual(
            StableIdentityDeriver.userID(deviceUUID: "device-xyz", virtualUserKey: key),
            "device-xyz:\(key)"
        )
    }

    func testBuiltInMaskDoesNotAddAdHocVirtualUser() {
        let users = VirtualUserRegistry.users(
            for: .full,
            questionnaire: .sample,
            deviceUUID: "device-xyz"
        )

        XCTAssertEqual(users.count, 16)
        XCTAssertEqual(users.map(\.key), VirtualUserRegistry.builtInKeys)
    }

    func testAdHocVirtualUserIsAddedWhenMaskDoesNotMatchBuiltIns() {
        let willingness = PermissionWillingness(
            location: .approximate,
            motion: .none,
            health: .noWatch,
            microphone: .none,
            calendar: .full,
            audioRoute: .unknown,
            network: .weakCellular,
            questionnaire: .basic
        )
        let users = VirtualUserRegistry.users(
            for: willingness,
            questionnaire: QuestionnaireState(primaryIntent: .commute),
            deviceUUID: "device-xyz"
        )

        XCTAssertEqual(users.count, 17)
        guard let adHoc = users.last else {
            return XCTFail("Expected ad hoc user")
        }
        XCTAssertTrue(adHoc.key.hasPrefix("u_ad_hoc_"))
        XCTAssertEqual(adHoc.userID, "device-xyz:\(adHoc.key)")
    }
}
