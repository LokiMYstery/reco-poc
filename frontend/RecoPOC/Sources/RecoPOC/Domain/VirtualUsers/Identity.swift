import Foundation

public enum StableIdentityDeriver {
    public static func userID(deviceUUID: String, virtualUserKey: String) -> String {
        "\(deviceUUID):\(virtualUserKey)"
    }

    public static func adHocVirtualUserKey(willingness: PermissionWillingness, questionnaire: QuestionnaireState) -> String {
        "u_ad_hoc_\(stableHashPrefix(canonicalRepresentation(willingness: willingness, questionnaire: questionnaire)))"
    }

    public static func canonicalRepresentation(willingness: PermissionWillingness, questionnaire: QuestionnaireState) -> String {
        let pairs: [(String, String)] = [
            ("audio_route", jsonString(willingness.audioRoute.rawValue)),
            ("calendar", jsonString(willingness.calendar.rawValue)),
            ("gender", questionnaire.gender.map { jsonString($0.rawValue) } ?? "null"),
            ("health", jsonString(willingness.health.rawValue)),
            ("initial_need", canonicalInitialNeed(questionnaire).map(jsonString) ?? "null"),
            ("initial_needs", jsonArray(questionnaire.secondaryIntents.map(\.rawValue).sorted())),
            ("intent_available", questionnaire.intentAvailable ? "true" : "false"),
            ("location", jsonString(willingness.location.rawValue)),
            ("microphone", jsonString(willingness.microphone.rawValue)),
            ("motion", jsonString(willingness.motion.rawValue)),
            ("network", jsonString(willingness.network.rawValue)),
            ("questionnaire", jsonString(willingness.questionnaire.rawValue)),
            ("questionnaire_available", questionnaire.questionnaireAvailable ? "true" : "false"),
            ("user_tag", questionnaire.userTag.map { jsonString($0.rawValue) } ?? "null")
        ].sorted { $0.0 < $1.0 }
        return "{" + pairs.map { "\(jsonString($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    public static func stableHashPrefix(_ text: String, length: Int = 12) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let full = String(format: "%016llx", hash)
        return String(full.prefix(length))
    }

    private static func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func jsonArray(_ values: [String]) -> String {
        "[" + values.map(jsonString).joined(separator: ",") + "]"
    }

    private static func canonicalInitialNeed(_ questionnaire: QuestionnaireState) -> String? {
        if let primaryIntent = questionnaire.primaryIntent {
            return primaryIntent.rawValue
        }
        return questionnaire.secondaryIntents.map(\.rawValue).sorted().first
    }
}
