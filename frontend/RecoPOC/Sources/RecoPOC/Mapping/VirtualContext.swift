import Foundation

public struct VirtualContext: Codable, Equatable, Sendable {
    public let virtualUser: VirtualUser
    public let fields: [String: JSONValue]

    public init(virtualUser: VirtualUser, fields: [String: JSONValue]) {
        self.virtualUser = virtualUser
        self.fields = fields
    }
}

public protocol VirtualContextDeriving: Sendable {
    func derive(snapshot: RawSensorSnapshot, virtualUser: VirtualUser, questionnaire: QuestionnaireState) -> VirtualContext
}

public struct VirtualContextDeriver: VirtualContextDeriving {
    public init() {}

    public func derive(snapshot: RawSensorSnapshot, virtualUser: VirtualUser, questionnaire: QuestionnaireState) -> VirtualContext {
        var fields: [String: JSONValue] = [
            "timestamp": .string(Self.formatTimestamp(snapshot.capturedAt)),
            "timezone": .string(snapshot.timezone),
            "hour": .int(snapshot.hour),
            "weekday": .int(snapshot.weekday),
            "network": .string(maskedNetwork(snapshot.network, mask: virtualUser.mask.network)),
            "bluetooth": .string(virtualUser.mask.audioRoute == .unknown ? "任意" : snapshot.bluetooth),
            "app_event": .string(snapshot.appEvent),
            "app_event_available": .int(1)
        ]

        applyLocation(snapshot, mask: virtualUser.mask.location, into: &fields)
        applyMotion(snapshot, mask: virtualUser.mask.motion, into: &fields)
        applyHealth(snapshot, mask: virtualUser.mask.health, into: &fields)
        applyMicrophone(snapshot, mask: virtualUser.mask.microphone, into: &fields)
        applyCalendar(snapshot, mask: virtualUser.mask.calendar, into: &fields)
        applyQuestionnaire(questionnaire, mask: virtualUser.mask.questionnaire, into: &fields)

        return VirtualContext(virtualUser: virtualUser, fields: fields)
    }

    private func maskedNetwork(_ network: String, mask: NetworkMask) -> String {
        mask == .weakCellular ? "蜂窝数据（弱）" : network
    }

    private func applyLocation(_ snapshot: RawSensorSnapshot, mask: LocationMask, into fields: inout [String: JSONValue]) {
        switch mask {
        case .full:
            fields["place_type"] = .string(snapshot.placeType)
            fields["place_type_available"] = .int(snapshot.placeTypeAvailable ? 1 : 0)
            fields["place_type_confidence"] = .double(snapshot.placeTypeConfidence)
            fields["place_type_quality"] = .string(snapshot.placeTypeQuality)
            if let latitude = snapshot.latitude { fields["latitude"] = .double(latitude) }
            if let longitude = snapshot.longitude { fields["longitude"] = .double(longitude) }
            if let accuracy = snapshot.locationAccuracyM { fields["location_accuracy_m"] = .double(accuracy) }
        case .approximate:
            fields["place_type"] = .string(snapshot.placeTypeAvailable ? snapshot.placeType : "任意")
            fields["place_type_available"] = .int(snapshot.placeTypeAvailable ? 1 : 0)
            fields["place_type_confidence"] = .double(min(snapshot.placeTypeConfidence, 0.25))
            fields["place_type_quality"] = .string("noisy_mapping")
            if let latitude = snapshot.latitude { fields["latitude"] = .double((latitude * 100).rounded() / 100) }
            if let longitude = snapshot.longitude { fields["longitude"] = .double((longitude * 100).rounded() / 100) }
            fields["location_accuracy_m"] = .double(max(snapshot.locationAccuracyM ?? 1000, 1000))
        case .none:
            fields["place_type"] = .string("任意")
            fields["place_type_available"] = .int(0)
            fields["place_type_confidence"] = .double(0)
            fields["place_type_quality"] = .string("unavailable")
        }
    }

    private func applyMotion(_ snapshot: RawSensorSnapshot, mask: MotionMask, into fields: inout [String: JSONValue]) {
        switch mask {
        case .full:
            fields["activity_state"] = .string(snapshot.activityState)
            fields["activity_state_available"] = .int(snapshot.activityStateAvailable ? 1 : 0)
        case .none:
            fields["activity_state"] = .string("任意")
            fields["activity_state_available"] = .int(0)
        }
    }

    private func applyHealth(_ snapshot: RawSensorSnapshot, mask: HealthMask, into fields: inout [String: JSONValue]) {
        switch mask {
        case .full:
            if let zone = snapshot.heartRateZone { fields["heart_rate_zone"] = .string(zone) }
            fields["heart_rate_available"] = .int(snapshot.heartRateAvailable ? 1 : 0)
            if let steps = snapshot.stepsLast10Min { fields["steps_last_10min"] = .int(steps) }
            if let workout = snapshot.recentWorkoutMinutes24h { fields["recent_workout_minutes_24h"] = .int(workout) }
            if let sleep = snapshot.sleepQuality { fields["sleep_quality"] = .string(sleep) }
        case .stepsOnly:
            if let steps = snapshot.stepsLast10Min { fields["steps_last_10min"] = .int(steps) }
            fields["heart_rate_available"] = .int(0)
        case .noWatch:
            fields["heart_rate_available"] = .int(0)
            if let steps = snapshot.stepsLast10Min { fields["steps_last_10min"] = .int(steps) }
            if let workout = snapshot.recentWorkoutMinutes24h { fields["recent_workout_minutes_24h"] = .int(workout) }
        case .none:
            fields["heart_rate_available"] = .int(0)
        }
    }

    private func applyMicrophone(_ snapshot: RawSensorSnapshot, mask: PrivacyMask, into fields: inout [String: JSONValue]) {
        switch mask {
        case .full:
            if let noise = snapshot.noiseClass { fields["noise_class"] = .string(noise) }
            fields["noise_available"] = .int(snapshot.noiseAvailable ? 1 : 0)
        case .none:
            fields["noise_available"] = .int(0)
        }
    }

    private func applyCalendar(_ snapshot: RawSensorSnapshot, mask: PrivacyMask, into fields: inout [String: JSONValue]) {
        switch mask {
        case .full:
            if let keyword = snapshot.calendarKeyword { fields["calendar_title"] = .string(keyword) }
            fields["calendar_available"] = .int(snapshot.calendarAvailable ? 1 : 0)
        case .none:
            fields["calendar_available"] = .int(0)
        }
    }

    private func applyQuestionnaire(_ questionnaire: QuestionnaireState, mask: QuestionnaireMask, into fields: inout [String: JSONValue]) {
        switch mask {
        case .full:
            fields.merge(questionnaire.contextFields()) { _, new in new }
        case .basic:
            var basic = QuestionnaireState(primaryIntent: questionnaire.initialNeed, secondaryIntents: [], userTag: questionnaire.userTag, gender: nil)
            if basic.primaryIntent == nil, let first = questionnaire.secondaryIntents.first { basic.primaryIntent = first }
            fields.merge(basic.contextFields(includeMultipleNeeds: false)) { _, new in new }
        case .none:
            fields["questionnaire_available"] = .int(0)
            fields["intent_available"] = .int(0)
        }
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }
}
