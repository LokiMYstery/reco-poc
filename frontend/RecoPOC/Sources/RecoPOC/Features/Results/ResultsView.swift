import SwiftUI

struct ResultsView: View {
    let model: ResultsScreenModel
    let onRetryFeedbackNow: () -> Void

    var body: some View {
        List {
            Section("Grouped recommendation results") {
                ForEach(model.groups) { group in
                    ResultGroupSummaryCard(group: group)
                }
            }

            if let feedbackStatus = model.feedbackStatus {
                Section("Feedback retry status") {
                    Text("Queued items: \(feedbackStatus.queuedCount)")
                    Text(feedbackStatus.nextRetryLabel)
                        .foregroundStyle(.secondary)
                    if let lastError = feedbackStatus.lastError {
                        Text(lastError)
                            .foregroundStyle(.orange)
                    }
                    Button("Retry now", action: onRetryFeedbackNow)
                        .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Results")
    }
}
