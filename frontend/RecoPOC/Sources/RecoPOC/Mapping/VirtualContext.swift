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

        applyLocation(snapshot, locationMask: virtualUser.mask.location, motionMask: virtualUser.mask.motion, into: &fields)
        applyMotion(snapshot, mask: virtualUser.mask.motion, into: &fields)
        applyHealth(snapshot, mask: virtualUser.mask.health, into: &fields)
        applyMicrophone(snapshot, mask: virtualUser.mask.microphone, into: &fields)
        applyCalendar(snapshot, mask: virtualUser.mask.calendar, into: &fields)
        applyWeather(snapshot, into: &fields)
        applyQuestionnaire(questionnaire, mask: virtualUser.mask.questionnaire, into: &fields)

        return VirtualContext(virtualUser: virtualUser, fields: fields)
    }

    private func maskedNetwork(_ network: String, mask: NetworkMask) -> String {
        mask == .weakCellular ? "蜂窝数据（弱）" : network
    }

    private func applyLocation(
        _ snapshot: RawSensorSnapshot,
        locationMask: LocationMask,
        motionMask: MotionMask,
        into fields: inout [String: JSONValue]
    ) {
        switch locationMask {
        case .full:
            let includeRawMotion = motionMask == .full
            let refinedPlace = PlaceTransitRefiner.refine(
                placeType: snapshot.placeType,
                placeTypeAvailable: snapshot.placeTypeAvailable,
                placeTypeConfidence: snapshot.placeTypeConfidence,
                placeTypeQuality: snapshot.placeTypeQuality,
                placeSource: snapshot.placeSource,
                placeCandidates: snapshot.placeCandidates,
                movementState: snapshot.movementState(includeRawMotionActivity: includeRawMotion),
                rawMotionActivity: includeRawMotion ? snapshot.rawMotionActivity : nil
            )
            fields["place_type"] = .string(refinedPlace.placeType)
            fields["place_type_available"] = .int(refinedPlace.placeTypeAvailable ? 1 : 0)
            fields["place_type_confidence"] = .double(refinedPlace.placeTypeConfidence)
            fields["place_type_quality"] = .string(refinedPlace.placeTypeQuality)
            if !refinedPlace.placeCandidates.isEmpty {
                fields["place_candidates"] = .array(refinedPlace.placeCandidates.map(\.jsonValue))
            }
            if let latitude = snapshot.latitude { fields["latitude"] = .double(latitude) }
            if let longitude = snapshot.longitude { fields["longitude"] = .double(longitude) }
            if let accuracy = snapshot.locationAccuracyM { fields["location_accuracy_m"] = .double(accuracy) }
        case .approximate:
            if snapshot.placeTypeAvailable {
                fields["place_type"] = .string(snapshot.placeType)
                fields["place_type_available"] = .int(1)
                fields["place_type_confidence"] = .double(min(snapshot.placeTypeConfidence, 0.25))
                fields["place_type_quality"] = .string("noisy_mapping")
                let candidates = snapshot.placeCandidates.map { candidate in
                    PlaceCandidate(
                        placeType: candidate.placeType,
                        confidence: min(candidate.confidence, 0.25),
                        distanceM: candidate.distanceM,
                        source: candidate.source,
                        quality: "noisy_mapping"
                    ).jsonValue
                }
                if !candidates.isEmpty {
                    fields["place_candidates"] = .array(candidates)
                }
            } else {
                fields["place_type"] = .string("任意")
                fields["place_type_available"] = .int(0)
                fields["place_type_confidence"] = .double(0)
                fields["place_type_quality"] = .string("unavailable")
            }
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


    private func applyWeather(_ snapshot: RawSensorSnapshot, into fields: inout [String: JSONValue]) {
        if let weather = snapshot.weather { fields["weather"] = .string(weather) }
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

struct RefinedPlace: Equatable, Sendable {
    var placeType: String
    var placeTypeAvailable: Bool
    var placeTypeConfidence: Double
    var placeTypeQuality: String
    var placeCandidates: [PlaceCandidate]
}

enum PlaceTransitRefiner {
    private static let staticPOITypes: Set<String> = [
        "住宅区",
        "商场",
        "酒店",
        "餐厅",
        "公园",
        "写字楼",
        "图书馆",
        "运动场所"
    ]
    private static let transitEvidenceTypes: Set<String> = [
        "机场",
        "高铁站",
        "地铁站",
        "在途"
    ]
    private static let strongRegeoSources: Set<String> = [
        "amap_regeo_building",
        "amap_regeo_neighborhood"
    ]

    static func refine(
        placeType: String,
        placeTypeAvailable: Bool,
        placeTypeConfidence: Double,
        placeTypeQuality: String,
        placeSource: String?,
        placeCandidates: [PlaceCandidate],
        movementState: MovementState,
        rawMotionActivity: String?
    ) -> RefinedPlace {
        let original = RefinedPlace(
            placeType: placeType,
            placeTypeAvailable: placeTypeAvailable,
            placeTypeConfidence: placeTypeConfidence,
            placeTypeQuality: placeTypeQuality,
            placeCandidates: placeCandidates
        )
        guard isStrongTransit(rawMotionActivity: rawMotionActivity, movementState: movementState) else {
            return original
        }
        guard !hasProtectedEvidence(placeType: placeType, placeSource: placeSource, candidates: placeCandidates) else {
            return original
        }
        guard !placeTypeAvailable || isAroundOnlyStaticPOI(placeType: placeType, placeSource: placeSource, candidates: placeCandidates) else {
            return original
        }

        let transitConfidence = min(0.85, max(0.65, placeTypeConfidence))
        let degradedCandidates = placeCandidates
            .filter { staticPOITypes.contains($0.placeType) }
            .map { candidate in
                PlaceCandidate(
                    placeType: candidate.placeType,
                    confidence: min(candidate.confidence, 0.25),
                    distanceM: candidate.distanceM,
                    source: candidate.source,
                    quality: "noisy_mapping"
                )
            }
        let candidates = Array((
            [PlaceCandidate(
                placeType: "在途",
                confidence: transitConfidence,
                source: "frontend_transit_refiner",
                quality: "transit_refined"
            )] + degradedCandidates
        ).prefix(3))
        return RefinedPlace(
            placeType: "在途",
            placeTypeAvailable: true,
            placeTypeConfidence: transitConfidence,
            placeTypeQuality: "transit_refined",
            placeCandidates: candidates
        )
    }

    private static func isStrongTransit(rawMotionActivity: String?, movementState: MovementState) -> Bool {
        rawMotionActivity == "automotive" || ((movementState.speedKmh ?? 0) >= 25 && movementState.speedQuality == "valid")
    }

    private static func hasProtectedEvidence(placeType: String, placeSource: String?, candidates: [PlaceCandidate]) -> Bool {
        if transitEvidenceTypes.contains(placeType) { return true }
        if let placeSource, strongRegeoSources.contains(placeSource) { return true }
        return candidates.contains { candidate in
            transitEvidenceTypes.contains(candidate.placeType) || strongRegeoSources.contains(candidate.source)
        }
    }

    private static func isAroundOnlyStaticPOI(placeType: String, placeSource: String?, candidates: [PlaceCandidate]) -> Bool {
        guard staticPOITypes.contains(placeType) else {
            return candidates.isEmpty && placeType == "任意"
        }
        let sources = ([placeSource].compactMap { $0 } + candidates.map(\.source))
            .filter { !$0.isEmpty }
        guard !sources.isEmpty else { return true }
        return sources.allSatisfy { $0.hasPrefix("amap_around") }
    }
}
