import SwiftUI

struct DiagnosticsView: View {
    let model: DiagnosticsScreenModel

    var body: some View {
        List {
            Section("Run log") {
                if let export = model.runLogExport {
                    ShareLink(item: export.fileURL) {
                        Label("Export Run Log", systemImage: "square.and.arrow.up")
                    }
                    Text(export.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Run a recommendation to export sensor acquisition diagnostics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sensor groups") {
                ForEach(model.sensorStatuses) { status in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status.title)
                                .font(.headline)
                            Text(status.status)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(status.durationLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Timing log") {
                ForEach(model.timingEvents) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.title)
                                .font(.headline)
                            Spacer()
                            Text(event.timestampLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(event.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Notes") {
                ForEach(model.notes, id: \.self) { note in
                    Text("• \(note)")
                }
            }
        }
        .navigationTitle("Timing & Diagnostics")
    }
}
