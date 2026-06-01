import SwiftUI

struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct StageIndicatorRow: View {
    let stage: RunStageRowModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconTint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(stage.title)
                    .font(.headline)
                Text(stage.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch stage.style {
        case .idle:
            return "circle.dashed"
        case .inFlight:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconTint: Color {
        switch stage.style {
        case .idle:
            return .secondary
        case .inFlight:
            return .blue
        case .success:
            return .green
        case .failure:
            return .orange
        }
    }
}

struct ResultGroupSummaryCard: View {
    let group: ResultGroupModel

    var body: some View {
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

struct TagCloud: View {
    let options: [String]
    let selectedValues: Set<String>
    let onToggle: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    onToggle(option)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selectedValues.contains(option) ? "checkmark.circle.fill" : "circle")
                        Text(option)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(selectedValues.contains(option) ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
