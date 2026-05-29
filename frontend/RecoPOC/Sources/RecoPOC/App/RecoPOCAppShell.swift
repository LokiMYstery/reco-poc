import SwiftUI

struct RecoPOCAppShell<Model: RecoPOCAppModeling>: View {
    @ObservedObject var model: Model
    @State private var selectedTab: Tab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeRunView(
                    model: model.homeScreen,
                    onOpenSetup: { selectedTab = .setup },
                    onStartRun: model.startRun,
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
                    onSelectScene: model.selectTrueScene(_:),
                    onSubmitFeedback: model.submitFeedbackSelection,
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
