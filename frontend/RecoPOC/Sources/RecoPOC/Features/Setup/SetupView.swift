import SwiftUI

struct SetupView: View {
    let model: SetupScreenModel
    let onSkip: () -> Void
    let onRequestPermissionMaintenance: (String) -> Void
    let onChangeWillingness: (String, PermissionWillingnessOption) -> Void
    let onSetQuestionnaireSkipped: (Bool) -> Void
    let onSetPrimaryIntent: (String?) -> Void
    let onToggleAdditionalNeed: (String) -> Void
    let onSetUserTag: (String) -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.banner.title)
                            .font(.headline)
                        Spacer()
                        StatusBadge(text: model.banner.isReady ? "Ready" : "Optional", tint: model.banner.isReady ? .green : .orange)
                    }
                    Text(model.banner.detail)
                        .foregroundStyle(.secondary)
                    Button("Skip Setup", action: onSkip)
                }
            } header: {
                Text("Experiment Setup")
            }

            Section("Permission willingness") {
                ForEach(model.permissions) { permission in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(permission.title)
                                    .font(.headline)
                                Text(permission.signalSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Maintain") {
                                onRequestPermissionMaintenance(permission.id)
                            }
                            .buttonStyle(.bordered)
                        }

                        HStack {
                            Text("System: \(permission.systemStatus)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        Picker(permission.title, selection: Binding(
                            get: { permission.willingness },
                            set: { onChangeWillingness(permission.id, $0) }
                        )) {
                            ForEach(PermissionWillingnessOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Toggle("Skip questionnaire entirely", isOn: Binding(
                    get: { model.questionnaire.isSkipped },
                    set: { isSkipped in onSetQuestionnaireSkipped(isSkipped) }
                ))

                if !model.questionnaire.isSkipped {
                    Picker("Primary intent", selection: Binding(
                        get: { model.questionnaire.primaryIntent ?? "" },
                        set: { onSetPrimaryIntent($0.isEmpty ? nil : $0) }
                    )) {
                        Text("Not selected").tag("")
                        ForEach(model.questionnaire.availablePrimaryIntents, id: \.self) { intent in
                            Text(intent).tag(intent)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Additional needs")
                            .font(.headline)
                        TagCloud(
                            options: model.questionnaire.availablePrimaryIntents,
                            selectedValues: Set(model.questionnaire.additionalNeeds),
                            onToggle: onToggleAdditionalNeed
                        )
                    }
                    .padding(.vertical, 4)

                    Picker("User tag", selection: Binding(
                        get: { model.questionnaire.userTag },
                        set: { userTag in onSetUserTag(userTag) }
                    )) {
                        ForEach(model.questionnaire.availableUserTags, id: \.self) { tag in
                            Text(tag).tag(tag)
                        }
                    }
                }
            } header: {
                Text("Questionnaire")
            } footer: {
                Text(model.derivedUserNote)
            }

            Section("Why this flow exists") {
                ForEach(model.explanation, id: \.self) { line in
                    Text("• \(line)")
                }
            }
        }
        .navigationTitle("Setup")
    }
}
