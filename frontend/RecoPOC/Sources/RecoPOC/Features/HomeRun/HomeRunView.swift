import SwiftUI

struct HomeRunView: View {
    let model: HomeRunScreenModel
    let onOpenSetup: () -> Void
    let onStartRun: () -> Void
    let onToggleTrueScene: (String) -> Void
    let onSubmitFeedback: () -> Void
    let onOpenResults: () -> Void

    private let sceneColumns = [GridItem(.adaptive(minimum: 90), spacing: 10)]

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
                    Text(model.flowInstructions)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Setup", action: onOpenSetup)
                            .buttonStyle(.bordered)
                        Button(model.primaryActionTitle, action: onStartRun)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text("Run")
            }

            Section {
                if let featuredResult = model.featuredResult {
                    ResultGroupSummaryCard(group: featuredResult)
                } else {
                    Text(model.latestResultsSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Full access recommendation")
            } footer: {
                Text("Home shows only the full-access virtual user; open grouped results for all virtual users.")
            }

            Section {
                LazyVGrid(columns: sceneColumns, alignment: .leading, spacing: 10) {
                    ForEach(model.sceneOptions, id: \.self) { scene in
                        let isSelected = model.selectedScenes.contains(scene)
                        let isBlockedByLimit = !isSelected && model.selectedScenes.count >= model.maxTrueSceneSelections
                        Button {
                            onToggleTrueScene(scene)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                Text(scene)
                                    .font(.subheadline.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 10)
                            .background((isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canSelectTrueScenes || isBlockedByLimit)
                    }
                }

                Text("Selected \(model.selectedScenes.count)/\(model.maxTrueSceneSelections): \(model.selectedScenes.isEmpty ? "None" : model.selectedScenes.joined(separator: ", "))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(model.feedbackSubmitTitle, action: onSubmitFeedback)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSubmitFeedback)
            } header: {
                Text("True Scene Selector (select at least 1, up to 3)")
            } footer: {
                Text("Each selected scene sends one correction feedback item for every successful virtual user result.")
            }

            Section("Progress") {
                Text(model.progressSummary)
                    .font(.subheadline)
                ForEach(model.runStages) { stage in
                    StageIndicatorRow(stage: stage)
                }
            }

            Section("This run's sensor inputs") {
                Text(model.sensorSnapshotSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(model.sensorSnapshotRows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.title)
                                .font(.headline)
                            Spacer()
                            Text(row.value)
                                .multilineTextAlignment(.trailing)
                        }
                        if let detail = row.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
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
