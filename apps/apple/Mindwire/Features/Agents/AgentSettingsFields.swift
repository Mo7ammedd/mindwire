import SwiftUI

/// Shared by agent settings and the chat sheet. Field names, choices, limits,
/// and model capabilities come from the workspace's harness adapter.
struct AgentSettingsFields: View {
    let schema: DaemonSettingsSchema
    @Binding var values: [String: String]
    var models: [DaemonModelInfo] = []
    var loadingModels = false
    var visibleCanons: [String]? = nil

    var body: some View {
        ForEach(Array(schema.sections.enumerated()), id: \.offset) { _, section in
            let fields = section.fields.filter {
                $0.type != .secret && $0.isVisible(values: values)
                    && (visibleCanons == nil || visibleCanons!.contains($0.canon ?? $0.key))
            }
            if !fields.isEmpty {
                Section(section.title) {
                    ForEach(fields) { field in
                        AgentSettingRow(field: field, schema: schema, values: $values, models: models)
                    }
                    if loadingModels && fields.contains(where: { $0.canon == "model" }) {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                            Text(t("agentSettings.models.loading")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

enum AgentSettingsDraft {
    static func model(in schema: DaemonSettingsSchema, values: [String: String], models: [DaemonModelInfo]) -> DaemonModelInfo? {
        guard let field = schema.sections.flatMap(\.fields).first(where: { $0.canon == "model" }) else { return nil }
        let selected = values[field.key] ?? ""
        return selected.isEmpty ? models.first(where: { $0.default == true }) : models.first(where: { $0.id == selected })
    }

    static func choices(for field: DaemonField, schema: DaemonSettingsSchema, values: [String: String], models: [DaemonModelInfo]) -> [DaemonFieldOption] {
        if field.canon == "reasoningEffort",
           let choices = model(in: schema, values: values, models: models)?.reasoningEfforts, !choices.isEmpty {
            return choices
        }
        return field.options ?? []
    }

    static func selectModel(_ id: String, field: DaemonField, schema: DaemonSettingsSchema,
                            models: [DaemonModelInfo], values: inout [String: String]) {
        guard values[field.key] != id else { return }
        values[field.key] = id
        guard let effort = schema.sections.flatMap(\.fields).first(where: { $0.canon == "reasoningEffort" }),
              let supported = model(in: schema, values: values, models: models)?.reasoningEfforts else { return }
        // Preserve compatible choices; switching models must not carry an
        // unsupported effort into the next turn. Blank selects the native default.
        if !supported.contains(where: { $0.value == values[effort.key] }) { values[effort.key] = "" }
    }

    static func changes(_ draft: [String: String], from baseline: [String: String]) -> [String: String] {
        draft.filter { $0.value != baseline[$0.key] }
    }
}

private struct AgentSettingRow: View {
    let field: DaemonField
    let schema: DaemonSettingsSchema
    @Binding var values: [String: String]
    let models: [DaemonModelInfo]

    private var value: Binding<String> {
        Binding(get: { values[field.key] ?? field.default ?? "" }, set: { values[field.key] = $0 })
    }

    private var choices: [DaemonFieldOption] {
        AgentSettingsDraft.choices(for: field, schema: schema, values: values, models: models)
    }

    private var defaultLabel: String {
        if field.canon == "reasoningEffort",
           let effort = AgentSettingsDraft.model(in: schema, values: values, models: models)?.defaultReasoningEffort {
            return t("agentSettings.defaultValue", ["value": effort])
        }
        return t("agentSettings.default")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            control
                .accessibilityIdentifier("agent.setting.\(field.canon ?? field.key)")
            if let help = choices.first(where: { $0.value == value.wrappedValue })?.help ?? field.help, !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if field.canon == "model" {
            NavigationLink {
                AgentModelPicker(models: modelChoices, selected: value.wrappedValue) { selection in
                    AgentSettingsDraft.selectModel(selection, field: field, schema: schema, models: models, values: &values)
                }
            } label: {
                LabeledContent(field.label, value: modelLabel)
            }
        } else if field.type == .select || (field.canon == "reasoningEffort" && !choices.isEmpty) {
            Picker(field.label, selection: value) {
                if !choices.contains(where: { $0.value.isEmpty }) { Text(defaultLabel).tag("") }
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                if !value.wrappedValue.isEmpty, !choices.contains(where: { $0.value == value.wrappedValue }) {
                    Text(value.wrappedValue).tag(value.wrappedValue)
                }
            }
        } else {
            switch field.type {
            case .text:
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(field.label).font(.subheadline).foregroundStyle(.secondary)
                    TextField(field.label, text: value, prompt: Text(field.placeholder ?? t("agentSettings.default")))
                        .keyboardType(field.inputMode == "numeric" ? .numberPad : field.inputMode == "url" ? .URL : .default)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            case .toggle:
                Toggle(field.label, isOn: Binding(get: { value.wrappedValue == "true" }, set: { value.wrappedValue = $0 ? "true" : "false" }))
            case .multiselect:
                MultiSelectField(label: field.label, options: choices, value: value)
            case .secret, .select:
                EmptyView()
            }
        }
    }

    private var modelLabel: String {
        if value.wrappedValue.isEmpty { return t("agentSettings.default") }
        return modelChoices.first(where: { $0.id == value.wrappedValue })?.label ?? value.wrappedValue
    }

    private var modelChoices: [DaemonModelInfo] {
        var choices = models
        for option in field.options ?? [] where !option.value.isEmpty && !choices.contains(where: { $0.id == option.value }) {
            choices.append(DaemonModelInfo(id: option.value, label: option.label))
        }
        return choices
    }
}

private struct AgentModelPicker: View {
    let models: [DaemonModelInfo]
    let selected: String
    let select: (String) -> Void
    @State private var search = ""
    @State private var custom = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [DaemonModelInfo] {
        models.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                choice("", title: t("agentSettings.default"))
                ForEach(filtered) { model in
                    choice(model.id, title: model.label, detail: model.label == model.id ? nil : model.id)
                }
            }
            Section {
                TextField(t("agentSettings.models.customPlaceholder"), text: $custom)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button(t("agentSettings.models.useCustom")) { choose(custom.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text(t("agentSettings.models.custom")) }
            footer: { Text(t("agentSettings.models.customHelp")) }
        }
        .searchable(text: $search, prompt: t("agentSettings.models.search"))
        .navigationTitle(t("agentSettings.models.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { custom = selected }
    }

    private func choice(_ id: String, title: String, detail: String? = nil) -> some View {
        Button { choose(id) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected == id { AppIcon(.check).foregroundStyle(Palette.accent) }
            }
        }
    }

    private func choose(_ id: String) { select(id); dismiss() }
}
