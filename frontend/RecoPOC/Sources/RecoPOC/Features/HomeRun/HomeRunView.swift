import SwiftUI

struct HomeRunView: View {
    let model: HomeRunScreenModel
    let onOpenSetup: () -> Void
    let onStartRun: () -> Void
    let onOpenResults: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.setupBanner.title)
                                .font(.headline)
                            Text(model.setupBanner.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(text: model.setupBanner.isReady ? "Ready" : "Needs review", tint: model.setupBanner.isReady ? .green : .orange)
                    }
                    HStack(spacing: 12) {
                        Button("Maintain Setup", action: onOpenSetup)
                            .buttonStyle(.bordered)
                        Button(model.primaryActionTitle, action: onStartRun)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text("Run")
            }

            Section("Progress") {
                Text(model.progressSummary)
                    .font(.subheadline)
                ForEach(model.runStages) { stage in
                    StageIndicatorRow(stage: stage)
                }
            }

            Section("Latest results") {
                Text(model.latestResultsSummary)
                Button("Open grouped results", action: onOpenResults)
                    .buttonStyle(.bordered)
                    .disabled(!model.canOpenResults)
            }

            if let retryStatus = model.retryStatus {
                Section("Feedback retry status") {
                    Text("Queued items: \(retryStatus.queuedCount)")
                    Text(retryStatus.nextRetryLabel)
                        .foregroundStyle(.secondary)
                    if let lastError = retryStatus.lastError {
                        Text(lastError)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Home")
    }
}
