import SwiftUI

struct ResultsView: View {
    let model: ResultsScreenModel
    let onSelectScene: (String) -> Void
    let onSelectPlayedRatioPct: (Double?) -> Void
    let onSelectNextAction: (String?) -> Void
    let onSubmitFeedback: () -> Void
    let onRetryFeedbackNow: () -> Void

    private let sceneColumns = [GridItem(.adaptive(minimum: 90), spacing: 10)]

    private var playedRatioSelection: Binding<String> {
        Binding(
            get: {
                guard let value = model.feedbackQuality.selectedPlayedRatioPct else { return "unset" }
                return String(value)
            },
            set: { rawValue in
                onSelectPlayedRatioPct(rawValue == "unset" ? nil : Double(rawValue))
            }
        )
    }

    private var nextActionSelection: Binding<String> {
        Binding(
            get: { model.feedbackQuality.selectedNextAction ?? "unset" },
            set: { rawValue in
                onSelectNextAction(rawValue == "unset" ? nil : rawValue)
            }
        )
    }

    var body: some View {
        List {
            Section("Grouped recommendation results") {
                ForEach(model.groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.userTitle)
                                    .font(.headline)
                                Text(group.userSubtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                StatusBadge(text: group.requestStatus, tint: group.errorMessage == nil ? .green : .orange)
                                Text(group.latencyLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let topRecommendation = group.topRecommendation {
                            Label("Top-1: \(topRecommendation)", systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                        }

                        if group.recommendations.isEmpty {
                            Text(group.errorMessage ?? "No recommendations available.")
                                .foregroundStyle(.orange)
                        } else {
                            ForEach(group.recommendations) { item in
                                HStack {
                                    Text("#\(item.rank) \(item.sceneName)")
                                    Spacer()
                                    Text(item.confidenceLabel)
                                        .foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                LazyVGrid(columns: sceneColumns, alignment: .leading, spacing: 10) {
                    ForEach(model.sceneOptions, id: \.self) { scene in
                        Button {
                            onSelectScene(scene)
                        } label: {
                            Text(scene)
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background((model.selectedScene == scene ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let selectedScene = model.selectedScene {
                    Text("Selected true scene: \(selectedScene)")
                        .font(.headline)
                }

                if let dwellTimeSec = model.feedbackQuality.dwellTimeSec {
                    Text("Measured dwell time: \(dwellTimeSec) s")
                        .foregroundStyle(.secondary)
                }

                Picker("Played ratio (optional)", selection: playedRatioSelection) {
                    ForEach(model.feedbackQuality.playedRatioPctOptions) { option in
                        Text(option.title).tag(option.value ?? "unset")
                    }
                }

                Picker("Next action (optional)", selection: nextActionSelection) {
                    ForEach(model.feedbackQuality.nextActionOptions) { option in
                        Text(option.title).tag(option.value ?? "unset")
                    }
                }

                Button("Submit correction feedback", action: onSubmitFeedback)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedScene == nil)
            } header: {
                Text("True scene selector — fixed 18 scenes")
            } footer: {
                Text("Feedback should only submit for virtual users with successful Top-1 recommendations.")
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
