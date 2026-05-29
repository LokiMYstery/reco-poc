import Foundation

public enum LocationMask: String, Codable, CaseIterable, Sendable { case full, approximate, none }
public enum MotionMask: String, Codable, CaseIterable, Sendable { case full, none }
public enum HealthMask: String, Codable, CaseIterable, Sendable { case full, stepsOnly = "steps_only", noWatch = "no_watch", none }
public enum PrivacyMask: String, Codable, CaseIterable, Sendable { case full, none }
public enum AudioRouteMask: String, Codable, CaseIterable, Sendable { case full, unknown }
public enum NetworkMask: String, Codable, CaseIterable, Sendable { case full, weakCellular = "weak_cellular" }
public enum QuestionnaireMask: String, Codable, CaseIterable, Sendable { case full, basic, none }

public struct PermissionMask: Codable, Equatable, Hashable, Sendable {
    public var location: LocationMask
    public var motion: MotionMask
    public var health: HealthMask
    public var microphone: PrivacyMask
    public var calendar: PrivacyMask
    public var audioRoute: AudioRouteMask
    public var network: NetworkMask
    public var questionnaire: QuestionnaireMask

    public init(
        location: LocationMask,
        motion: MotionMask,
        health: HealthMask,
        microphone: PrivacyMask,
        calendar: PrivacyMask,
        audioRoute: AudioRouteMask = .full,
        network: NetworkMask = .full,
        questionnaire: QuestionnaireMask
    ) {
        self.location = location
        self.motion = motion
        self.health = health
        self.microphone = microphone
        self.calendar = calendar
        self.audioRoute = audioRoute
        self.network = network
        self.questionnaire = questionnaire
    }
}

public struct PermissionWillingness: Codable, Equatable, Hashable, Sendable {
    public var location: LocationMask
    public var motion: MotionMask
    public var health: HealthMask
    public var microphone: PrivacyMask
    public var calendar: PrivacyMask
    public var audioRoute: AudioRouteMask
    public var network: NetworkMask
    public var questionnaire: QuestionnaireMask

    public init(
        location: LocationMask,
        motion: MotionMask,
        health: HealthMask,
        microphone: PrivacyMask,
        calendar: PrivacyMask,
        audioRoute: AudioRouteMask = .full,
        network: NetworkMask = .full,
        questionnaire: QuestionnaireMask
    ) {
        self.location = location
        self.motion = motion
        self.health = health
        self.microphone = microphone
        self.calendar = calendar
        self.audioRoute = audioRoute
        self.network = network
        self.questionnaire = questionnaire
    }

    public static let full = PermissionWillingness(
        location: .full,
        motion: .full,
        health: .full,
        microphone: .full,
        calendar: .full,
        audioRoute: .full,
        network: .full,
        questionnaire: .full
    )

    public var asMask: PermissionMask {
        PermissionMask(
            location: location,
            motion: motion,
            health: health,
            microphone: microphone,
            calendar: calendar,
            audioRoute: audioRoute,
            network: network,
            questionnaire: questionnaire
        )
    }
}

public enum PermissionWillingnessChoice: String, Codable, Equatable, Hashable, Sendable {
    case wouldGrant = "would_grant"
    case wouldNotGrant = "would_not_grant"
    case unsure
}

public struct PermissionWillingnessAnnotations: Codable, Equatable, Hashable, Sendable {
    public var location: PermissionWillingnessChoice
    public var motion: PermissionWillingnessChoice
    public var health: PermissionWillingnessChoice
    public var microphone: PermissionWillingnessChoice
    public var calendar: PermissionWillingnessChoice
    public var audioRoute: PermissionWillingnessChoice
    public var network: PermissionWillingnessChoice
    public var isQuestionnaireSkipped: Bool
    public var questionnaire: QuestionnaireState

    public init(
        location: PermissionWillingnessChoice,
        motion: PermissionWillingnessChoice,
        health: PermissionWillingnessChoice,
        microphone: PermissionWillingnessChoice,
        calendar: PermissionWillingnessChoice,
        audioRoute: PermissionWillingnessChoice = .wouldGrant,
        network: PermissionWillingnessChoice = .wouldGrant,
        isQuestionnaireSkipped: Bool,
        questionnaire: QuestionnaireState
    ) {
        self.location = location
        self.motion = motion
        self.health = health
        self.microphone = microphone
        self.calendar = calendar
        self.audioRoute = audioRoute
        self.network = network
        self.isQuestionnaireSkipped = isQuestionnaireSkipped
        self.questionnaire = questionnaire
    }

    public var willingness: PermissionWillingness {
        PermissionWillingness(
            location: Self.locationMask(for: location),
            motion: Self.motionMask(for: motion),
            health: Self.healthMask(for: health),
            microphone: Self.privacyMask(for: microphone),
            calendar: Self.privacyMask(for: calendar),
            audioRoute: Self.audioRouteMask(for: audioRoute),
            network: Self.networkMask(for: network),
            questionnaire: questionnaireMask
        )
    }

    private var questionnaireMask: QuestionnaireMask {
        guard !isQuestionnaireSkipped else { return .none }
        if questionnaire.primaryIntent != nil { return .full }
        if questionnaire.questionnaireAvailable { return .basic }
        return .none
    }

    private static func locationMask(for choice: PermissionWillingnessChoice) -> LocationMask {
        switch choice {
        case .wouldGrant: return .full
        case .wouldNotGrant: return .none
        case .unsure: return .approximate
        }
    }

    private static func motionMask(for choice: PermissionWillingnessChoice) -> MotionMask {
        choice == .wouldGrant ? .full : .none
    }

    private static func healthMask(for choice: PermissionWillingnessChoice) -> HealthMask {
        switch choice {
        case .wouldGrant: return .full
        case .wouldNotGrant: return .none
        case .unsure: return .stepsOnly
        }
    }

    private static func privacyMask(for choice: PermissionWillingnessChoice) -> PrivacyMask {
        choice == .wouldGrant ? .full : .none
    }

    private static func audioRouteMask(for choice: PermissionWillingnessChoice) -> AudioRouteMask {
        choice == .wouldGrant ? .full : .unknown
    }

    private static func networkMask(for choice: PermissionWillingnessChoice) -> NetworkMask {
        choice == .wouldGrant ? .full : .weakCellular
    }
}

public struct VirtualUserDefinition: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let displayName: String
    public let purpose: String
    public let mask: PermissionMask

    public init(key: String, displayName: String, purpose: String, mask: PermissionMask) {
        self.key = key
        self.displayName = displayName
        self.purpose = purpose
        self.mask = mask
    }
}

public struct VirtualUser: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let key: String
    public let displayName: String
    public let purpose: String
    public let mask: PermissionMask
    public let userID: String
    public var id: String { key }

    public init(key: String, displayName: String, purpose: String, mask: PermissionMask, userID: String) {
        self.key = key
        self.displayName = displayName
        self.purpose = purpose
        self.mask = mask
        self.userID = userID
    }
}
