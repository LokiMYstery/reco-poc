import SwiftUI

struct RecoPOCAppShell<Model: RecoPOCAppModeling>: View {
    @ObservedObject var model: Model
    @State private var selectedTab: Tab = .home
    @State private var isShowingFirstInstallPermissions = false
    @AppStorage("RecoPOC.firstInstallPermissionPrompt.v1") private var didShowFirstInstallPermissionPrompt = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeRunView(
                    model: model.homeScreen,
                    onOpenSetup: { selectedTab = .setup },
                    onStartRun: model.startRun,
                    onToggleTrueScene: model.toggleTrueSceneSelection(_:),
                    onSubmitFeedback: model.submitFeedbackSelection,
                    onOpenResults: { selectedTab = .results }
                )
            }
            .tabItem {
                Label("Home", systemImage: "play.circle")
            }
            .tag(Tab.home)

            NavigationStack {
                SetupView(
                    model: model.setupScreen,
                    onSkip: model.skipSetup,
                    onRequestPermissionMaintenance: model.requestPermissionMaintenance(for:),
                    onChangeWillingness: model.updateWillingness(for:to:),
                    onSetQuestionnaireSkipped: model.setQuestionnaireSkipped,
                    onSetPrimaryIntent: model.setPrimaryIntent,
                    onToggleAdditionalNeed: model.toggleAdditionalNeed,
                    onSetUserTag: model.setUserTag
                )
            }
            .tabItem {
                Label("Setup", systemImage: "slider.horizontal.3")
            }
            .tag(Tab.setup)

            NavigationStack {
                VirtualUsersView(users: model.virtualUsers)
            }
            .tabItem {
                Label("Users", systemImage: "person.3")
            }
            .tag(Tab.users)

            NavigationStack {
                ResultsView(
                    model: model.resultsScreen,
                    onRetryFeedbackNow: model.retryFailedFeedbackNow
                )
            }
            .tabItem {
                Label("Results", systemImage: "chart.bar.doc.horizontal")
            }
            .tag(Tab.results)

            NavigationStack {
                DiagnosticsView(model: model.diagnosticsScreen)
            }
            .tabItem {
                Label("Timing", systemImage: "clock.badge.checkmark")
            }
            .tag(Tab.timing)
        }
        .onAppear {
            if !didShowFirstInstallPermissionPrompt {
                isShowingFirstInstallPermissions = true
            }
        }
        .sheet(isPresented: $isShowingFirstInstallPermissions) {
            FirstInstallPermissionPromptView(
                onRequestAll: {
                    didShowFirstInstallPermissionPrompt = true
                    isShowingFirstInstallPermissions = false
                    model.requestAllPermissionMaintenance()
                },
                onOpenSetup: {
                    didShowFirstInstallPermissionPrompt = true
                    isShowingFirstInstallPermissions = false
                    selectedTab = .setup
                }
            )
        }
    }
}

private struct FirstInstallPermissionPromptView: View {
    let onRequestAll: () -> Void
    let onOpenSetup: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "hand.raised.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)

                Text("Request permissions for the experiment")
                    .font(.title2.weight(.semibold))

                Text("For the first run, please allow all available permissions and network access so the full-access virtual user has the richest context and Run does not pause on system prompts. If you do not want to grant a permission, you can change it in Setup and complete or edit the questionnaire there.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Run uses whatever Setup already allowed.", systemImage: "checkmark.circle")
                    Label("Backend network access is warmed up before the first Run.", systemImage: "checkmark.circle")
                    Label("Recommendation runs will not interrupt subjects with prompts.", systemImage: "checkmark.circle")
                    Label("Questionnaire answers can be edited in Setup before any run.", systemImage: "checkmark.circle")
                }
                .font(.subheadline)

                Spacer()

                Button("Request all permissions now", action: onRequestAll)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                Button("Review in Setup instead", action: onOpenSetup)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("First setup")
        }
    }
}

private extension RecoPOCAppShell {
    enum Tab {
        case home
        case setup
        case users
        case results
        case timing
    }
}
