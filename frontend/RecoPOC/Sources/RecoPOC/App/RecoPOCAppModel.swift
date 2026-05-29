import Foundation
import SwiftUI

@MainActor
protocol RecoPOCAppModeling: ObservableObject {
    var setupScreen: SetupScreenModel { get }
    var homeScreen: HomeRunScreenModel { get }
    var virtualUsers: [VirtualUserRowModel] { get }
    var resultsScreen: ResultsScreenModel { get }
    var diagnosticsScreen: DiagnosticsScreenModel { get }

    func skipSetup()
    func requestPermissionMaintenance(for groupID: String)
    func updateWillingness(for groupID: String, to option: PermissionWillingnessOption)
    func setQuestionnaireSkipped(_ isSkipped: Bool)
    func setPrimaryIntent(_ value: String?)
    func toggleAdditionalNeed(_ value: String)
    func setUserTag(_ value: String)
    func startRun()
    func selectTrueScene(_ scene: String)
    func selectFeedbackPlayedRatioPct(_ value: Double?)
    func selectFeedbackNextAction(_ value: String?)
    func submitFeedbackSelection()
    func retryFailedFeedbackNow()
}

@MainActor
final class DemoRecoPOCAppModel: RecoPOCAppModeling {
    @Published private(set) var setupScreen: SetupScreenModel
    @Published private(set) var homeScreen: HomeRunScreenModel
    @Published private(set) var virtualUsers: [VirtualUserRowModel]
    @Published private(set) var resultsScreen: ResultsScreenModel
    @Published private(set) var diagnosticsScreen: DiagnosticsScreenModel

    private let container: DependencyContainer
    private let runCoordinator: RunCoordinator
    private let deviceUUID: String
    private var latestRunState: RunState?

    init(container: DependencyContainer = .demo(), deviceUUID: String? = nil) {
        self.container = container
        self.runCoordinator = container.makeRunCoordinator()
        self.deviceUUID = deviceUUID ?? container.installIdentityStore.stableDeviceUUID()

        let intents = InitialNeed.allCases.map(\.rawValue)
        let userTags = UserTag.allCases.map(\.rawValue)

        setupScreen = SetupScreenModel(
            banner: SetupBannerModel(
                title: "Setup is skippable but recommended",
                detail: "Granting more signals here lets the experiment derive missing-permission virtual users later.",
                isReady: false
            ),
            capabilityGate: SetupCapabilityGateModel(
                title: "Loading host/capability gate",
                summary: "Resolving baseline-safe vs native-capable setup path.",
                detail: "Setup owns permission/capability state; recommendation runs stay prompt-free.",
                readiness: .optional
            ),
            permissions: [
                .init(id: "location", title: "Location / Precise Location", signalSummary: "place_type, latitude, longitude", systemStatus: "Loading…", willingness: .wouldGrant),
                .init(id: "motion", title: "Motion & Fitness", signalSummary: "activity_state", systemStatus: "Loading…", willingness: .wouldGrant),
                .init(id: "health", title: "HealthKit", signalSummary: "heart_rate, steps, sleep", systemStatus: "Loading…", willingness: .unsure),
                .init(id: "microphone", title: "Microphone / Noise", signalSummary: "noise_class", systemStatus: "Loading…", willingness: .wouldNotGrant),
                .init(id: "calendar", title: "Calendar", signalSummary: "calendar keyword", systemStatus: "Loading…", willingness: .wouldNotGrant),
                .init(id: "audio_route", title: "Audio Route", signalSummary: "bluetooth-like output", systemStatus: "Loading…", willingness: .wouldGrant),
                .init(id: "network", title: "Network", signalSummary: "wifi / cellular quality", systemStatus: "Loading…", willingness: .wouldGrant),
                .init(id: "questionnaire", title: "Questionnaire Intent", signalSummary: "initial_need, initial_needs, user_tag", systemStatus: "Loading…", willingness: .unsure)
            ],
            questionnaire: QuestionnaireEditorModel(
                isSkipped: false,
                primaryIntent: InitialNeed.relax.rawValue,
                additionalNeeds: [InitialNeed.sleep.rawValue, InitialNeed.reading.rawValue],
                userTag: UserTag.student.rawValue,
                availablePrimaryIntents: intents,
                availableUserTags: userTags
            ),
            derivedUserNote: "",
            explanation: [
                "The real subject should grant permissions where possible for richer raw snapshots.",
                "Virtual users simulate online missing-data scenarios by masking one frozen snapshot.",
                "Questionnaire intent is optional and can be edited later without blocking runs.",
                "RunCoordinator stays prompt-free; setup owns host/capability status and permission maintenance state."
            ]
        )

        homeScreen = DemoRecoPOCAppModel.makeHomeScreen()
        resultsScreen = DemoRecoPOCAppModel.makeResultsScreen(sceneOptions: SceneCatalog.names)
        diagnosticsScreen = DemoRecoPOCAppModel.makeDiagnosticsScreen()
        virtualUsers = []
        refreshPermissionCapabilityStatuses()
        syncDerivedState()
    }

    func skipSetup() {
        setupScreen.banner.isReady = true
        setupScreen.banner.title = "Setup skipped"
        setupScreen.banner.detail = "You can revisit permissions and questionnaire anytime before the next run."
        refreshHomeBanner()
    }

    func requestPermissionMaintenance(for groupID: String) {
        guard let index = setupScreen.permissions.firstIndex(where: { $0.id == groupID }) else { return }
        setupScreen.permissions[index].systemStatus = container.permissionCapabilityStatusProvider.maintenanceLabel(for: groupID)
    }

    func updateWillingness(for groupID: String, to option: PermissionWillingnessOption) {
        guard let index = setupScreen.permissions.firstIndex(where: { $0.id == groupID }) else { return }
        setupScreen.permissions[index].willingness = option
        syncDerivedState()
    }

    func setQuestionnaireSkipped(_ isSkipped: Bool) {
        setupScreen.questionnaire.isSkipped = isSkipped
        if isSkipped {
            setupScreen.questionnaire.primaryIntent = nil
            setupScreen.questionnaire.additionalNeeds.removeAll()
            setupScreen.questionnaire.userTag = UserTag.any.rawValue
        }
        syncDerivedState()
    }

    func setPrimaryIntent(_ value: String?) {
        guard !setupScreen.questionnaire.isSkipped else { return }
        setupScreen.questionnaire.primaryIntent = value
        syncDerivedState()
    }

    func toggleAdditionalNeed(_ value: String) {
        guard !setupScreen.questionnaire.isSkipped else { return }
        if let index = setupScreen.questionnaire.additionalNeeds.firstIndex(of: value) {
            setupScreen.questionnaire.additionalNeeds.remove(at: index)
        } else {
            setupScreen.questionnaire.additionalNeeds.append(value)
        }
        syncDerivedState()
    }

    func setUserTag(_ value: String) {
        guard !setupScreen.questionnaire.isSkipped else { return }
        setupScreen.questionnaire.userTag = value
        syncDerivedState()
    }

    func startRun() {
        homeScreen.progressSummary = "Recommendation run in progress."
        homeScreen.runStages = [
            .init(id: "acquire", title: "Data acquisition", detail: "Starting 15s bounded snapshot", style: .inFlight),
            .init(id: "derive", title: "Derive virtual contexts", detail: "Waiting for snapshot", style: .idle),
            .init(id: "recommend", title: "Recommend fan-out", detail: "Waiting for virtual contexts", style: .idle),
            .init(id: "feedback", title: "Feedback gate", detail: "Waiting for true scene selection", style: .idle)
        ]
        homeScreen.canOpenResults = false
        resetFeedbackSelections()

        let users = currentVirtualUsers()
        let questionnaire = currentQuestionnaireState()

        Task {
            let state = await runCoordinator.runRecommendation(virtualUsers: users, questionnaire: questionnaire)
            applyRunState(state)
        }
    }

    func selectTrueScene(_ scene: String) {
        resultsScreen.selectedScene = scene
    }

    func selectFeedbackPlayedRatioPct(_ value: Double?) {
        resultsScreen.feedbackQuality.selectedPlayedRatioPct = value
    }

    func selectFeedbackNextAction(_ value: String?) {
        resultsScreen.feedbackQuality.selectedNextAction = value
    }

    func submitFeedbackSelection() {
        guard
            let selectedSceneName = resultsScreen.selectedScene,
            let selectedScene = SceneCatalog.scene(named: selectedSceneName),
            let latestRunState
        else { return }

        let quality = FeedbackQuality(
            dwellTimeSec: nil,
            playedRatioPct: resultsScreen.feedbackQuality.selectedPlayedRatioPct,
            nextAction: resultsScreen.feedbackQuality.selectedNextAction
        )

        Task {
            let feedbackState = await runCoordinator.submitFeedback(
                selectedScene: selectedScene,
                from: latestRunState,
                quality: quality.isEmpty ? nil : quality
            )
            applyFeedbackState(feedbackState)
        }
    }

    func retryFailedFeedbackNow() {
        Task {
            let jobs = await runCoordinator.retryQueuedFeedbackNow()
            let status = retryStatus(from: jobs)
            resultsScreen.feedbackStatus = status
            homeScreen.retryStatus = status
        }
    }

    private func refreshHomeBanner() {
        homeScreen.setupBanner = setupScreen.banner
    }

    private func refreshPermissionCapabilityStatuses() {
        let snapshot = container.permissionCapabilityStatusProvider.snapshot()
        setupScreen.capabilityGate = SetupCapabilityGateModel(
            title: snapshot.gate.title,
            summary: snapshot.gate.summary,
            detail: snapshot.gate.detail,
            readiness: readiness(from: snapshot.gate.readiness)
        )

        let statusesByID = Dictionary(uniqueKeysWithValues: snapshot.permissions.map { ($0.id, $0) })
        for index in setupScreen.permissions.indices {
            guard let status = statusesByID[setupScreen.permissions[index].id] else { continue }
            setupScreen.permissions[index].systemStatus = status.statusText
        }

        setupScreen.banner.isReady = snapshot.permissions.allSatisfy { status in
            switch status.readiness {
            case .available, .optional:
                return true
            case .limited, .blocked, .requiresHost:
                return false
            }
        }

        if setupScreen.banner.isReady {
            setupScreen.banner.title = "Setup ready"
            setupScreen.banner.detail = "Baseline-safe capabilities are available for the next run."
        } else {
            setupScreen.banner.title = "Setup is skippable but recommended"
            setupScreen.banner.detail = snapshot.gate.summary
        }

        refreshHomeBanner()
    }

    private func syncDerivedState() {
        let users = currentVirtualUsers()
        virtualUsers = users.map { user in
            VirtualUserRowModel(
                id: user.key,
                title: user.key,
                maskSummary: user.purpose,
                isMatchedToLatestPreference: user.key.hasPrefix("u_ad_hoc_") || user.key == "u_ad_hoc_placeholder",
                isAdHoc: user.key.hasPrefix("u_ad_hoc_"),
                badges: badgeLabels(for: user)
            )
        }

        if let matched = users.last(where: { $0.key.hasPrefix("u_ad_hoc_") }) {
            setupScreen.derivedUserNote = "Latest willingness pattern needs an ad hoc virtual user placeholder for the next run: \(matched.key)."
        } else {
            setupScreen.derivedUserNote = "Latest willingness pattern matches an existing built-in virtual user."
        }
    }

    private func badgeLabels(for user: VirtualUser) -> [String] {
        var labels = [user.key.hasPrefix("u_ad_hoc_") ? "Ad hoc" : "Built-in"]
        if user.mask.questionnaire == .none {
            labels.append("No questionnaire")
        }
        if user.mask.location == .approximate {
            labels.append("Approx")
        }
        if user.mask.location == .none && user.mask.health == .none {
            labels.append("Minimal")
        }
        return labels
    }

    private func currentWillingness() -> PermissionWillingness {
        PermissionWillingnessAnnotations(
            location: choice(for: "location", default: .wouldGrant),
            motion: choice(for: "motion", default: .wouldGrant),
            health: choice(for: "health", default: .unsure),
            microphone: choice(for: "microphone", default: .wouldNotGrant),
            calendar: choice(for: "calendar", default: .wouldNotGrant),
            audioRoute: choice(for: "audio_route", default: .wouldGrant),
            network: choice(for: "network", default: .wouldGrant),
            isQuestionnaireSkipped: setupScreen.questionnaire.isSkipped,
            questionnaire: currentQuestionnaireState()
        ).willingness
    }

    private func currentQuestionnaireState() -> QuestionnaireState {
        guard !setupScreen.questionnaire.isSkipped else { return .skipped }
        return QuestionnaireState(
            primaryIntent: initialNeed(from: setupScreen.questionnaire.primaryIntent),
            secondaryIntents: setupScreen.questionnaire.additionalNeeds.compactMap(initialNeed(from:)),
            userTag: userTag(from: setupScreen.questionnaire.userTag),
            gender: nil
        )
    }

    private func permission(id: String) -> PermissionGroupRowModel? {
        setupScreen.permissions.first(where: { $0.id == id })
    }

    private func choice(for permissionID: String, default defaultChoice: PermissionWillingnessChoice) -> PermissionWillingnessChoice {
        permission(id: permissionID)?.willingness.choice ?? defaultChoice
    }

    private func currentVirtualUsers() -> [VirtualUser] {
        container.virtualUserProvider.users(
            for: currentWillingness(),
            questionnaire: currentQuestionnaireState(),
            deviceUUID: deviceUUID
        )
    }

    private func applyRunState(_ state: RunState) {
        latestRunState = state
        homeScreen.progressSummary = "Snapshot frozen, \(state.contexts.count) virtual contexts derived, \(state.results.filter(\.isSuccess).count)/\(state.results.count) recommendations succeeded."
        homeScreen.runStages = [
            .init(id: "acquire", title: "Data acquisition", detail: state.snapshot == nil ? "No snapshot" : "15s deadline respected", style: state.snapshot == nil ? .failure : .success),
            .init(id: "derive", title: "Derive virtual contexts", detail: "contexts=\(state.contexts.count)", style: .success),
            .init(id: "recommend", title: "Recommend fan-out", detail: "success=\(state.results.filter(\.isSuccess).count); failure=\(state.results.filter { !$0.isSuccess }.count)", style: .success),
            .init(id: "feedback", title: "Feedback gate", detail: "Waiting for true scene selection", style: .idle)
        ]
        homeScreen.latestResultsSummary = "Top-1 is ready for true-scene feedback across successful virtual users."
        homeScreen.canOpenResults = true
        resultsScreen.groups = state.results.map(resultGroup(from:))
        resultsScreen.feedbackQuality.dwellTimeSec = nil
        diagnosticsScreen.sensorStatuses = sensorStatuses(from: state.snapshot)
        diagnosticsScreen.timingEvents = timingEvents(from: state.timingEvents)
    }

    private func applyFeedbackState(_ state: RunState) {
        latestRunState = state
        let status = retryStatus(from: state.retryJobs)
        resultsScreen.feedbackStatus = status
        resultsScreen.feedbackQuality.dwellTimeSec = state.feedbackQuality?.dwellTimeSec
        homeScreen.retryStatus = status
        homeScreen.runStages = [
            .init(id: "acquire", title: "Data acquisition", detail: "Snapshot already frozen", style: .success),
            .init(id: "derive", title: "Derive virtual contexts", detail: "contexts=\(state.contexts.count)", style: .success),
            .init(id: "recommend", title: "Recommend fan-out", detail: "success=\(state.results.filter(\.isSuccess).count); failure=\(state.results.filter { !$0.isSuccess }.count)", style: .success),
            .init(id: "feedback", title: "Feedback submission", detail: state.retryQueueCount > 0 ? "\(state.retryQueueCount) queued for in-memory retry" : "Completed", style: state.retryQueueCount > 0 ? .inFlight : .success)
        ]
        diagnosticsScreen.timingEvents = timingEvents(from: state.timingEvents)
        diagnosticsScreen.notes = [
            "Feedback uses event_type=correction for every successful result group.",
            "Retry queue is in-memory for the current app process and is not cleared by starting another run.",
            "No impression event is emitted from this UI shell."
        ]
    }

    private func resultGroup(from result: RecommendationResult) -> ResultGroupModel {
        ResultGroupModel(
            id: result.requestID,
            userTitle: result.virtualUserKey,
            userSubtitle: result.userID,
            requestStatus: result.isSuccess ? "Success" : "Failed",
            topRecommendation: result.top1,
            latencyLabel: "\(result.latencyMs) ms",
            recommendations: result.topScenes.enumerated().map { index, scene in
                RecommendationItemModel(rank: index + 1, sceneName: scene, confidenceLabel: "Top \(index + 1)")
            },
            errorMessage: result.errorMessage
        )
    }

    private func sensorStatuses(from snapshot: RawSensorSnapshot?) -> [SensorStatusRowModel] {
        guard let snapshot else { return diagnosticsScreen.sensorStatuses }
        return snapshot.statuses.keys.sorted().map { key in
            let status = snapshot.statuses[key]
            return SensorStatusRowModel(
                id: key,
                title: key,
                status: status?.availability.rawValue ?? "unknown",
                durationLabel: status?.message ?? "captured"
            )
        }
    }

    private func timingEvents(from events: [TimingEvent]) -> [TimingEventRowModel] {
        events.enumerated().map { index, event in
            TimingEventRowModel(
                id: "\(index)-\(event.phase)",
                title: event.phase,
                timestampLabel: event.endedAt.map(Self.timeFormatter.string(from:)) ?? Self.timeFormatter.string(from: event.startedAt),
                detail: event.detail ?? Self.durationLabel(for: event)
            )
        }
    }

    private static func durationLabel(for event: TimingEvent) -> String {
        guard let endedAt = event.endedAt else { return "in flight" }
        let milliseconds = Int(max(0, endedAt.timeIntervalSince(event.startedAt) * 1000))
        return "\(milliseconds) ms"
    }

    private func retryStatus(from jobs: [FeedbackRetryJob]) -> RetryStatusModel {
        RetryStatusModel(
            queuedCount: jobs.count,
            nextRetryLabel: jobs.first.map { "Retry in \($0.secondsRemaining)s" } ?? "Queue empty",
            lastError: jobs.first?.lastError
        )
    }

    private func readiness(from readiness: PermissionCapabilityReadiness) -> CapabilityReadiness {
        switch readiness {
        case .available: return .available
        case .limited: return .limited
        case .blocked: return .blocked
        case .requiresHost: return .requiresHost
        case .optional: return .optional
        }
    }

    private func initialNeed(from value: String?) -> InitialNeed? {
        guard let value else { return nil }
        return InitialNeed.allCases.first(where: { $0.rawValue == value })
    }

    private func userTag(from value: String) -> UserTag? {
        UserTag.allCases.first(where: { $0.rawValue == value })
    }


    private func resetFeedbackSelections() {
        resultsScreen.selectedScene = nil
        resultsScreen.feedbackStatus = nil
        resultsScreen.feedbackQuality = Self.defaultFeedbackQualitySelection()
    }

    private static func defaultFeedbackQualitySelection() -> FeedbackQualitySelectionModel {
        FeedbackQualitySelectionModel(
            dwellTimeSec: nil,
            playedRatioPctOptions: [
                .init(title: "Not set", value: nil),
                .init(title: "25%", value: "0.25"),
                .init(title: "50%", value: "0.5"),
                .init(title: "75%", value: "0.75"),
                .init(title: "100%", value: "1.0")
            ],
            selectedPlayedRatioPct: nil,
            nextActionOptions: [
                .init(title: "Not set", value: nil),
                .init(title: "completed", value: "completed"),
                .init(title: "replay", value: "replay"),
                .init(title: "skip", value: "skip"),
                .init(title: "exit", value: "exit")
            ],
            selectedNextAction: nil
        )
    }

    private static func makeHomeScreen() -> HomeRunScreenModel {
        HomeRunScreenModel(
            setupBanner: SetupBannerModel(
                title: "Setup recommended before the first run",
                detail: "Host/capability status, willingness, and questionnaire can be edited later.",
                isReady: false
            ),
            primaryActionTitle: "Start Recommendation Run",
            progressSummary: "No run started yet.",
            runStages: [
                .init(id: "acquire", title: "Data acquisition", detail: "Waiting", style: .idle),
                .init(id: "derive", title: "Derive virtual contexts", detail: "Waiting", style: .idle),
                .init(id: "recommend", title: "Recommend fan-out", detail: "Waiting", style: .idle),
                .init(id: "feedback", title: "Feedback submission", detail: "Blocked until true scene selected", style: .idle)
            ],
            latestResultsSummary: "Results will group by virtual user after the first run.",
            retryStatus: RetryStatusModel(queuedCount: 1, nextRetryLabel: "Retry in 00:27", lastError: "Latest feedback batch had one simulated timeout."),
            canOpenResults: true
        )
    }

    private static func makeResultsScreen(sceneOptions: [String]) -> ResultsScreenModel {
        ResultsScreenModel(
            groups: [
                .init(
                    id: "u_full_permission",
                    userTitle: "u_full_permission",
                    userSubtitle: "All signals + questionnaire",
                    requestStatus: "Success",
                    topRecommendation: "放松",
                    latencyLabel: "412 ms",
                    recommendations: [
                        .init(rank: 1, sceneName: "放松", confidenceLabel: "0.81"),
                        .init(rank: 2, sceneName: "冥想", confidenceLabel: "0.67"),
                        .init(rank: 3, sceneName: "减压", confidenceLabel: "0.54")
                    ],
                    errorMessage: nil
                ),
                .init(
                    id: "u_weak_cellular_commuter",
                    userTitle: "u_weak_cellular_commuter",
                    userSubtitle: "Weak cellular + transit-biased",
                    requestStatus: "Success",
                    topRecommendation: "通勤",
                    latencyLabel: "921 ms",
                    recommendations: [
                        .init(rank: 1, sceneName: "通勤", confidenceLabel: "0.72"),
                        .init(rank: 2, sceneName: "游戏", confidenceLabel: "0.50"),
                        .init(rank: 3, sceneName: "阅读", confidenceLabel: "0.39")
                    ],
                    errorMessage: nil
                ),
                .init(
                    id: "u_ad_hoc_placeholder",
                    userTitle: "u_ad_hoc_placeholder",
                    userSubtitle: "Derived from latest willingness/questionnaire pattern",
                    requestStatus: "Failed",
                    topRecommendation: nil,
                    latencyLabel: "1.5 s",
                    recommendations: [],
                    errorMessage: "Simulated backend timeout for ad hoc feedback readiness."
                )
            ],
            sceneOptions: sceneOptions,
            selectedScene: SceneCatalog.names.last(where: { $0 == "冥想" }),
            feedbackQuality: defaultFeedbackQualitySelection(),
            feedbackStatus: RetryStatusModel(queuedCount: 1, nextRetryLabel: "Retry in 00:27", lastError: "One feedback item is queued after a simulated timeout.")
        )
    }

    private static func makeDiagnosticsScreen() -> DiagnosticsScreenModel {
        DiagnosticsScreenModel(
            sensorStatuses: [
                .init(id: "time", title: "Time fields", status: "Success", durationLabel: "0 ms"),
                .init(id: "network", title: "Network", status: "Success", durationLabel: "31 ms"),
                .init(id: "location", title: "Location / Place", status: "Success", durationLabel: "6.2 s"),
                .init(id: "motion", title: "Motion", status: "Success", durationLabel: "1.4 s"),
                .init(id: "health", title: "Health", status: "Unavailable / placeholder", durationLabel: "15 s deadline"),
                .init(id: "noise", title: "Noise", status: "Skipped", durationLabel: "0 ms"),
                .init(id: "calendar", title: "Calendar", status: "Denied", durationLabel: "0 ms")
            ],
            timingEvents: [
                .init(id: "open", title: "App opened", timestampLabel: "09:40:00", detail: "Initial shell visible"),
                .init(id: "setup", title: "Setup checked", timestampLabel: "09:40:02", detail: "Willingness and questionnaire loaded"),
                .init(id: "acquire", title: "Acquisition started", timestampLabel: "09:40:12", detail: "15s total deadline"),
                .init(id: "freeze", title: "Raw snapshot frozen", timestampLabel: "09:40:21", detail: "Completed at 9.6s"),
                .init(id: "virtual", title: "Virtual contexts derived", timestampLabel: "09:40:21", detail: "Built-in registry + optional ad hoc user"),
                .init(id: "recommend", title: "Recommend responses received", timestampLabel: "09:40:22", detail: "15 success / 1 failed / 1 queued"),
                .init(id: "select", title: "True scene selected", timestampLabel: "09:40:31", detail: "冥想"),
                .init(id: "feedback", title: "Feedback batch started", timestampLabel: "09:40:31", detail: "correction for every success result"),
                .init(id: "retry", title: "Feedback retry scheduled", timestampLabel: "09:40:32", detail: "in-memory queue only"),
                .init(id: "done", title: "Feedback responses updated", timestampLabel: "09:40:49", detail: "1 pending retry remains")
            ],
            notes: [
                "This shell intentionally keeps retry state in memory only.",
                "True scene selection is sourced from the shared 18-scene domain catalog.",
                "Replace demo state with Lane 4 coordinator and Lane 1 domain catalog once those modules land."
            ]
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private extension PermissionWillingnessOption {
    var choice: PermissionWillingnessChoice {
        switch self {
        case .wouldGrant: return .wouldGrant
        case .wouldNotGrant: return .wouldNotGrant
        case .unsure: return .unsure
        }
    }
}
