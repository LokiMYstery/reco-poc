import Foundation

public enum InitialNeed: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case focus = "学习/工作专注"
    case sleep = "睡眠/午休"
    case relax = "放松/减压"
    case exercise = "运动/健身"
    case commute = "通勤/出行"
    case emotion = "情绪陪伴"
    case family = "家庭/照护"
    case gaming = "游戏娱乐"
    case reading = "阅读陪伴"
}

public enum UserTag: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case any = "任意"
    case student = "学生"
    case motherBaby = "母婴用户"
    case female = "女性"
    case petOwner = "养宠物"
}

public enum Gender: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case any = "任意"
    case female = "女性"
    case male = "男性"
    case undisclosed = "不便透露"
}

public struct QuestionnaireState: Codable, Equatable, Hashable, Sendable {
    public var primaryIntent: InitialNeed?
    public var secondaryIntents: [InitialNeed]
    public var userTag: UserTag?
    public var gender: Gender?

    public init(
        primaryIntent: InitialNeed? = nil,
        secondaryIntents: [InitialNeed] = [],
        userTag: UserTag? = nil,
        gender: Gender? = nil
    ) {
        self.primaryIntent = primaryIntent
        self.secondaryIntents = secondaryIntents
        self.userTag = userTag
        self.gender = gender
    }

    public static let skipped = QuestionnaireState()
    public static let sample = QuestionnaireState(
        primaryIntent: .focus,
        secondaryIntents: [.relax, .reading],
        userTag: .student,
        gender: .undisclosed
    )

    public var hasAnyIntent: Bool {
        primaryIntent != nil || !secondaryIntents.isEmpty
    }

    public var questionnaireAvailable: Bool {
        hasAnyIntent || userTag != nil || gender != nil
    }

    public var intentAvailable: Bool {
        hasAnyIntent
    }

    public var initialNeed: InitialNeed? {
        primaryIntent ?? secondaryIntents.first
    }

    public func contextFields(includeMultipleNeeds: Bool = true) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "questionnaire_available": .int(questionnaireAvailable ? 1 : 0),
            "intent_available": .int(intentAvailable ? 1 : 0)
        ]
        if let initialNeed {
            fields["intent"] = .string(initialNeed.rawValue)
            fields["initial_need"] = .string(initialNeed.rawValue)
        }
        if includeMultipleNeeds, !secondaryIntents.isEmpty {
            fields["initial_needs"] = .array(secondaryIntents.map { .string($0.rawValue) })
        }
        if let userTag {
            fields["user_tag"] = .string(userTag.rawValue)
        }
        if let gender {
            fields["gender"] = .string(gender.rawValue)
        }
        return fields
    }
}
