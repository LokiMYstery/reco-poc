import Foundation

struct SetupBannerModel {
    var title: String
    var detail: String
    var isReady: Bool
}

enum CapabilityReadiness: String {
    case available = "Available"
    case limited = "Limited"
    case blocked = "Blocked"
    case requiresHost = "Requires Host"
    case optional = "Optional"
}

struct SetupCapabilityGateModel {
    var title: String
    var summary: String
    var detail: String
    var readiness: CapabilityReadiness
}

enum PermissionWillingnessOption: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case wouldGrant = "Would grant"
    case wouldNotGrant = "Would not grant"
    case unsure = "Unsure"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

struct PermissionGroupRowModel: Identifiable {
    var id: String
    var title: String
    var signalSummary: String
    var systemStatus: String
    var systemDetail: String?
    var willingness: PermissionWillingnessOption
}

struct QuestionnaireEditorModel {
    var isSkipped: Bool
    var primaryIntent: String?
    var additionalNeeds: [String]
    var userTag: String
    var availablePrimaryIntents: [String]
    var availableUserTags: [String]
}

struct SetupScreenModel {
    var banner: SetupBannerModel
    var capabilityGate: SetupCapabilityGateModel
    var permissions: [PermissionGroupRowModel]
    var questionnaire: QuestionnaireEditorModel
    var derivedUserNote: String
    var explanation: [String]
}

enum RunStageStyle {
    case idle
    case inFlight
    case success
    case failure
}

struct RunStageRowModel: Identifiable {
    var id: String
    var title: String
    var detail: String
    var style: RunStageStyle
}

struct RetryStatusModel {
    var queuedCount: Int
    var nextRetryLabel: String
    var lastError: String?
}

struct SensorSnapshotRowModel: Identifiable, Equatable {
    var id: String
    var title: String
    var value: String
    var detail: String?
}

struct HomeRunScreenModel {
    var setupBanner: SetupBannerModel
    var primaryActionTitle: String
    var progressSummary: String
    var runStages: [RunStageRowModel]
    var sensorSnapshotSummary: String
    var sensorSnapshotRows: [SensorSnapshotRowModel]
    var latestResultsSummary: String
    var retryStatus: RetryStatusModel?
    var canOpenResults: Bool
}

struct VirtualUserRowModel: Identifiable {
    var id: String
    var title: String
    var maskSummary: String
    var isMatchedToLatestPreference: Bool
    var isAdHoc: Bool
    var badges: [String]
}

struct RecommendationItemModel: Identifiable {
    var id: String { "\(rank)-\(sceneName)" }
    var rank: Int
    var sceneName: String
    var confidenceLabel: String
}

struct ResultGroupModel: Identifiable {
    var id: String
    var userTitle: String
    var userSubtitle: String
    var requestStatus: String
    var topRecommendation: String?
    var latencyLabel: String
    var recommendations: [RecommendationItemModel]
    var errorMessage: String?
}

struct FeedbackOptionModel: Identifiable, Equatable {
    var id: String { value ?? "unset" }
    var title: String
    var value: String?
}

struct FeedbackQualitySelectionModel {
    var dwellTimeSec: Int?
    var playedRatioPctOptions: [FeedbackOptionModel]
    var selectedPlayedRatioPct: Double?
    var nextActionOptions: [FeedbackOptionModel]
    var selectedNextAction: String?
}

struct ResultsScreenModel {
    var groups: [ResultGroupModel]
    var sceneOptions: [String]
    var selectedScene: String?
    var feedbackQuality: FeedbackQualitySelectionModel
    var feedbackStatus: RetryStatusModel?
}

struct SensorStatusRowModel: Identifiable {
    var id: String
    var title: String
    var status: String
    var durationLabel: String
}

struct TimingEventRowModel: Identifiable {
    var id: String
    var title: String
    var timestampLabel: String
    var detail: String
}

struct DiagnosticsScreenModel {
    var sensorStatuses: [SensorStatusRowModel]
    var timingEvents: [TimingEventRowModel]
    var notes: [String]
}
