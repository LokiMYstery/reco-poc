import Foundation

public struct RecommendRequest: Codable, Equatable, Sendable {
    public let userID: String
    public let requestID: String
    public let topK: Int
    public let context: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case requestID = "request_id"
        case topK = "top_k"
        case context
    }
}

public struct FeedbackRequest: Codable, Equatable, Sendable {
    public let userID: String
    public let requestID: String
    public let recommendedScene: String
    public let acceptedScene: String
    public let eventType: String
    public let dwellTimeSec: Int?
    public let playedRatioPct: Double?
    public let nextAction: String?

    public init(
        userID: String,
        requestID: String,
        recommendedScene: String,
        acceptedScene: String,
        eventType: String,
        dwellTimeSec: Int? = nil,
        playedRatioPct: Double? = nil,
        nextAction: String? = nil
    ) {
        self.userID = userID
        self.requestID = requestID
        self.recommendedScene = recommendedScene
        self.acceptedScene = acceptedScene
        self.eventType = eventType
        self.dwellTimeSec = dwellTimeSec
        self.playedRatioPct = playedRatioPct
        self.nextAction = nextAction
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case requestID = "request_id"
        case recommendedScene = "recommended_scene"
        case acceptedScene = "accepted_scene"
        case eventType = "event_type"
        case dwellTimeSec = "dwell_time_sec"
        case playedRatioPct = "played_ratio_pct"
        case nextAction = "next_action"
    }
}

public protocol BackendPayloadMapping: Sendable {
    func recommendPayload(context: VirtualContext, requestID: String, topK: Int) -> RecommendRequest
    func feedbackPayload(result: RecommendationResult, acceptedScene: RecoScene) -> FeedbackRequest?
}

public struct BackendPayloadMapper: BackendPayloadMapping {
    public init() {}

    public func recommendPayload(context: VirtualContext, requestID: String, topK: Int = 3) -> RecommendRequest {
        RecommendRequest(
            userID: context.virtualUser.userID,
            requestID: requestID,
            topK: topK,
            context: context.fields
        )
    }

    public func feedbackPayload(result: RecommendationResult, acceptedScene: RecoScene) -> FeedbackRequest? {
        guard let top1 = result.topScenes.first else { return nil }
        return FeedbackRequest(
            userID: result.userID,
            requestID: result.requestID,
            recommendedScene: top1,
            acceptedScene: acceptedScene.name,
            eventType: "correction"
        )
    }
}
