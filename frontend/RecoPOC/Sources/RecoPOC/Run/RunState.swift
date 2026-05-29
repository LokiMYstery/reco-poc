import Foundation

public enum RunPhase: String, Codable, Equatable, Sendable {
    case idle
    case acquiring
    case deriving
    case recommending
    case awaitingTrueScene
    case sendingFeedback
    case retryingFeedback
    case completed
    case failed
}

public struct TimingEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let phase: String
    public let startedAt: Date
    public var endedAt: Date?
    public var detail: String?

    public var durationMs: Int? {
        endedAt.map { Int($0.timeIntervalSince(startedAt) * 1000) }
    }

    public init(id: UUID = UUID(), phase: String, startedAt: Date = Date(), endedAt: Date? = nil, detail: String? = nil) {
        self.id = id
        self.phase = phase
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.detail = detail
    }
}

public struct FeedbackQuality: Codable, Equatable, Sendable {
    public var dwellTimeSec: Int?
    public var playedRatioPct: Double?
    public var nextAction: String?

    public init(dwellTimeSec: Int? = nil, playedRatioPct: Double? = nil, nextAction: String? = nil) {
        self.dwellTimeSec = dwellTimeSec
        self.playedRatioPct = playedRatioPct
        self.nextAction = nextAction
    }

    public var isEmpty: Bool {
        dwellTimeSec == nil && playedRatioPct == nil && nextAction == nil
    }
}

public struct RunState: Codable, Equatable, Sendable {
    public var phase: RunPhase
    public var snapshot: RawSensorSnapshot?
    public var contexts: [VirtualContext]
    public var results: [RecommendationResult]
    public var feedbackJobs: [FeedbackRequest]
    public var retryQueueCount: Int
    public var retryJobs: [FeedbackRetryJob]
    public var timingEvents: [TimingEvent]
    public var errorMessage: String?
    public var selectedTrueScene: String?
    public var feedbackQuality: FeedbackQuality?

    public init(
        phase: RunPhase,
        snapshot: RawSensorSnapshot? = nil,
        contexts: [VirtualContext] = [],
        results: [RecommendationResult] = [],
        feedbackJobs: [FeedbackRequest] = [],
        retryQueueCount: Int = 0,
        retryJobs: [FeedbackRetryJob] = [],
        timingEvents: [TimingEvent] = [],
        errorMessage: String? = nil,
        selectedTrueScene: String? = nil,
        feedbackQuality: FeedbackQuality? = nil
    ) {
        self.phase = phase
        self.snapshot = snapshot
        self.contexts = contexts
        self.results = results
        self.feedbackJobs = feedbackJobs
        self.retryQueueCount = retryQueueCount
        self.retryJobs = retryJobs
        self.timingEvents = timingEvents
        self.errorMessage = errorMessage
        self.selectedTrueScene = selectedTrueScene
        self.feedbackQuality = feedbackQuality
    }

    public static let idle = RunState(phase: .idle)
}
