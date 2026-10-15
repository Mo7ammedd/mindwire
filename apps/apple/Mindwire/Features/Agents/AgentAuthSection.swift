import SwiftUI
import UIKit

/// One sheet slot for the auth UI. SwiftUI only reliably presents ONE `.sheet` per view, so the
/// method flow and the config-file editor share a single item-driven sheet (two `.sheet`s on the
/// same view silently fought each other — the config editor never opened).
enum AuthSheetItem: Identifiable {
    case method(DaemonAuthMethod)
    case config
    var id: String {
        switch self {
        case .method(let m): return "method:\(m.id)"
        case .config: return "config"
        }
    }
}

@MainActor @Observable
final class AgentAuthPresentation {
    var sheet: AuthSheetItem?
}

private struct AgentAuthPresentationKey: EnvironmentKey {
    static let defaultValue: AgentAuthPresentation? = nil
}

extension EnvironmentValues {
    var agentAuthPresentation: AgentAuthPresentation? {
        get { self[AgentAuthPresentationKey.self] }
        set { self[AgentAuthPresentationKey.self] = newValue }
    }
}

/// The presenter outlives readiness transitions. A status refresh or returning
/// from the browser must not remove the view that owns an unfinished sign-in.
struct AgentAuthPresenter<Content: View>: View {
    let model: DaemonSession?
    @State var presentation = AgentAuthPresentation()
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.agentAuthPresentation, presentation)
            .sheet(item: $presentation.sheet, onDismiss: {
                model?.cancelInteractive()
                Task { await model?.refresh() }
            }) { item in
                if let model {
                    switch item {
                    case .method(let method): AgentAuthMethodSheet(model: model, method: method)
                    case .config: configFileEditor(model)
                    }
                }
            }
    }
}

/// The agent's config file opened in the code editor — the SAME `FileEditorScreen` the Files
/// browser uses (a config file is just a file at a path on the workspace; no special handling).
@MainActor @ViewBuilder
private func configFileEditor(_ model: DaemonSession) -> some View {
    if let workspace = model.workspace, let path = model.configPath {
        NavigationStack {
            FileEditorScreen(workspace: workspace, path: path, createIfMissing: true)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text(configFileHelp(model))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.md)
                        .background(.bar)
                }
        }
    }
}

/// Shared by the authentication screen and agent settings. Shows the live
/// connection status and one row per auth method the agent's daemon declares; tapping a method
/// opens its flow (a field form, or the interactive OAuth URL + poll). Credentials never touch the
/// device — the daemon persists them in the workspace.
struct AgentAuthSection: View {
    @Bindable var model: DaemonSession
    @Environment(\.agentAuthPresentation) private var presentation
    @State private var confirmingSignOut = false
    @State private var signOutError: String?

    var body: some View {
        Section {
            if model.preparing {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text(t("agentAuth.preparing")).foregroundStyle(.secondary)
                }
            } else if let error = model.loadError {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label(error, icon: .warning)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button(t("common.retry")) { Task { await model.load(force: true) } }
                        .tint(.primary)
                }
            } else {
                statusRow
                ForEach(model.methods) { method in
                    Button { presentation?.sheet = .method(method) } label: {
                        row(icon: method.interactive ? .userKey : .key,
                            title: method.label)
                    }
                    .tint(.primary)
                }
                if model.configPath != nil {
                    Button { presentation?.sheet = .config } label: {
                        row(icon: .fileText, title: t("agentAuth.configFile"))
                    }
                    .tint(.primary)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label(t("agentAuth.recheck"), icon: Icon.restart)
                }
                .tint(.primary)
                .disabled(model.loading || model.working)
                if model.isConfigured {
                    Button(role: .destructive) { confirmingSignOut = true } label: {
                        HStack {
                            Label(t("agentAuth.logout"), icon: .logout)
                                .foregroundStyle(Palette.danger)
                            if model.signingOut { Spacer(); ProgressView() }
                        }
                    }
                    .tint(Palette.danger)
                    .disabled(model.working || model.signingOut)
                }
            }
        } header: {
            Text(t("agentAuth.section"))
        } footer: {
            if !model.preparing, model.loadError == nil, model.methods.isEmpty, model.configPath == nil {
                Text(t("agentAuth.none"))
            }
        }
        .alert(t("agentAuth.logout.title"), isPresented: $confirmingSignOut) {
            Button(t("agentAuth.logout"), role: .destructive) {
                Task { do { try await model.signOut() } catch { signOutError = error.localizedDescription } }
            }
            Button(t("common.cancel"), role: .cancel) {}
        } message: { Text(t("agentAuth.logout.body")) }
        .alert(t("agentAuth.logout.failed"), isPresented: Binding(get: { signOutError != nil }, set: { if !$0 { signOutError = nil } })) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(signOutError ?? "") }
        .disabled(model.signingOut)
    }

    private var statusRow: some View {
        HStack(spacing: Spacing.sm) {
            AppIcon(model.isConfigured ? .verified : .shieldAlert)
                .foregroundStyle(.secondary)
            if model.isConfigured {
                if model.methods.first(where: { $0.id == model.status?.method })?.interactive == true,
                   let detail = model.status?.detail, !detail.isEmpty {
                    Text(detail)
                } else {
                    Text(t("agentAuth.connected", ["method": methodLabel(model.status?.method)]))
                }
            } else {
                Text(t("agentAuth.notConnected")).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.sm)
            if model.loading { ProgressView() }
        }
    }

    private func row(icon: AppIconName, title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            AppIcon(icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
            Spacer(minLength: Spacing.sm)
            AppIcon(Icon.chevron).font(.footnote).foregroundStyle(.tertiary)
        }
    }

    private func methodLabel(_ id: String?) -> String {
        guard let id else { return "" }
        if id == "configFile" { return t("agentAuth.nativeConfig") }
        return model.methods.first { $0.id == id }?.label ?? id
    }
}

/// Full-screen connect prompt shown when an agent is reachable but not yet authenticated (the
/// `.needsAuth` phase). Renders the agent's identity and its auth methods as prominent buttons;
/// completing any method flips the model to `.ready` and the detail page renders. Shares the same
/// `AgentAuthMethodSheet` flow as the settings section.
struct AgentConnectGate: View {
    let agent: Agent
    @Bindable var model: DaemonSession

    @Environment(\.agentAuthPresentation) private var presentation

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                header

                VStack(spacing: Spacing.sm) {
                    if model.methods.isEmpty, model.configPath == nil {
                        Text(t("agentAuth.none")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(model.methods) { method in
                        optionCard(icon: method.interactive ? .userKey : .key,
                                   title: method.label) { presentation?.sheet = .method(method) }
                    }
                    if model.configPath != nil {
                        optionCard(icon: .fileText, title: t("agentAuth.configFile")) { presentation?.sheet = .config }
                    }
                }

                if let error = model.connectError, !error.isEmpty {
                    Label(error, icon: .warning)
                        .font(.footnote)
                        .foregroundStyle(Palette.danger)
                }

                // Re-run the generic connectivity + auth check (e.g. after finishing a login, or if
                // creds were set another way) — flips straight to the agent page if it now passes.
                Button {
                    Task { await model.refresh() }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if model.loading { ProgressView().controlSize(.small) }
                        else { AppIcon(Icon.restart) }
                        Text(t("agentAuth.recheck"))
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .disabled(model.loading)
                .padding(.top, Spacing.xs)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    /// Real (colored) agent mark in a glass disc + title/subtitle.
    private var header: some View {
        VStack(spacing: Spacing.md) {
            AgentLogo(id: agent.agentType, size: 44)
                .frame(width: 76, height: 76)
                .glassEffect(.regular, in: .circle)
            VStack(spacing: Spacing.xs) {
                Text(t("agentAuth.gate.title")).font(.title2.weight(.semibold))
                Text(t("agentAuth.gate.body", ["name": agent.displayName]))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, Spacing.xl)
    }

    /// A tappable glass card; method guidance belongs inside the selected flow.
    private func optionCard(icon: AppIconName, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                AppIcon(icon)
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 26)
                Text(title).fontWeight(.medium).foregroundStyle(.primary)
                Spacer(minLength: Spacing.sm)
                AppIcon(Icon.chevron).font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
    }
}

/// The editor's instructions use the daemon's canonical path for each adapter.
@MainActor
private func configFileHelp(_ model: DaemonSession) -> String {
    t("agentAuth.configFile.help", ["path": model.configPath ?? ""])
}

/// Form guidance is a header, so the grouped row's rounded mask cannot clip the text.
@ViewBuilder
private func authMethodDescription(_ method: DaemonAuthMethod) -> some View {
    if let help = method.help, !help.isEmpty {
        Section {
        } header: {
            Text(help)
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(.horizontal, 0)
                .accessibilityRemoveTraits(.isHeader)
        }
    }
}

/// One method's flow: a field form (non-interactive, e.g. an API key) or the interactive OAuth URL
/// with a live poll (e.g. Sign in with Claude). Dismisses after this attempt succeeds, including
/// when the agent was already connected before the user chose a different account.
struct AgentAuthMethodSheet: View {
    @Bindable var model: DaemonSession
    let method: DaemonAuthMethod

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var values: [String: String] = [:]
    @State private var attemptedSubmit = false
    @FocusState private var focusedField: String?

    var body: some View {
        NavigationStack {
            Group {
                if method.interactive {
                    Form {
                        authMethodDescription(method)
                        interactiveBody
                        if let error = model.connectError, !error.isEmpty {
                            Section {
                                Label(error, icon: .warning)
                                    .foregroundStyle(Palette.danger)
                                if !model.working {
                                    Button(t("common.retry")) {
                                        values.removeAll()
                                        Task { await model.startInteractive(method) }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    AgentAuthForm(method: method, values: $values, working: model.working,
                                  error: model.connectError) {
                        Task {
                            if await model.submit(method: method, values: method.form.submissionValues(values)) {
                                values.removeAll()
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(method.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { model.cancelInteractive(); dismiss() }
                        .tint(.primary)
                }
            }
            .onChange(of: model.completedAuthMethod) { _, completed in
                if completed == method.id { dismiss() }
            }
            .task {
                if method.interactive {
                    await model.startInteractive(method)
                } else {
                    model.connectError = nil
                }
            }
        }
    }

    // MARK: Interactive method

    @ViewBuilder
    private var interactiveBody: some View {
        Section {
            if let code = model.loginCode, !code.isEmpty {
                LabeledContent(t("agentAuth.code")) {
                    Text(code).font(.title3.monospaced()).textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label(t("agentAuth.copyCode"), icon: .copy)
                }
                .tint(.primary)
                .accessibilityIdentifier("auth-copy-code")
                Button {
                    values.removeAll()
                    Task { await model.startInteractive(method) }
                } label: {
                    Label(t("agentAuth.newCode"), icon: .refresh)
                }
                .tint(.primary)
                .accessibilityIdentifier("auth-new-code")
            }
            if let url = model.loginURL, !url.isEmpty {
                Button {
                    if let u = URL(string: url) { openURL(u) }
                } label: {
                    Label(t("agentAuth.openUrl"), icon: .externalLink)
                }
                .tint(.primary)
                .accessibilityIdentifier("auth-open-sign-in")
                Button {
                    UIPasteboard.general.string = url
                } label: {
                    Label(t("agentAuth.copyUrl"), icon: .copy)
                }
                .tint(.primary)
            }
            HStack(spacing: Spacing.sm) {
                if model.working && model.loginFields.isEmpty { ProgressView() }
                Text(model.loginMessage ?? t("agentAuth.signInWait"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        ForEach(model.loginForm.visibleSections(values)) { section in
            Section {
                ForEach(section.fields) { field in
                    AgentAuthFieldInput(field: field, value: Binding(
                        get: { values[field.key] ?? field.default ?? "" },
                        set: { values[field.key] = $0 }
                    ), focusedField: $focusedField)
                    .accessibilityLabel(field.label)
                    .accessibilityIdentifier("auth-field-\(field.key)")
                }
            } header: {
                if !section.title.isEmpty { Text(section.title) }
            } footer: {
                if !section.help.isEmpty { Text(section.help) }
                if attemptedSubmit, let field = model.loginForm.firstInvalidField(values),
                   section.fields.contains(where: { $0.key == field.key }) {
                    Text(t("agentAuth.requiredField", ["field": field.label]))
                        .foregroundStyle(Palette.danger)
                }
            }
            .disabled(model.loginSubmitting)
        }
        if !model.loginFields.isEmpty {
            Section {
                Button {
                    attemptedSubmit = true
                    if let field = model.loginForm.firstInvalidField(values) {
                        focusedField = field.key
                        return
                    }
                    focusedField = nil
                    Task {
                        if await model.submitInteractive(values: values) { values.removeAll() }
                    }
                } label: {
                    HStack {
                        if model.loginSubmitting { ProgressView() }
                        Text(t("common.continue"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(Palette.accent)
                .disabled(model.loginSubmitting)
                .accessibilityIdentifier("auth-submit-code")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

}

/// Native form controls and section copy come entirely from the daemon's auth schema.
/// The Connect action scrolls with the fields at the end of the form.
struct AgentAuthForm: View {
    let method: DaemonAuthMethod
    @Binding var values: [String: String]
    let working: Bool
    let error: String?
    let onSubmit: () -> Void

    @FocusState private var focusedField: String?
    @State private var attemptedSubmit = false

    private var sections: [DaemonAuthFormSection] { method.form.visibleSections(values) }
    private var textFields: [DaemonField] {
        sections.flatMap(\.fields).filter { [.text, .secret, .multiselect].contains($0.type) }
    }

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                authMethodDescription(method)
                ForEach(sections) { section in
                    Section {
                        ForEach(section.fields) { field in
                            fieldInput(field)
                                .accessibilityLabel(field.label)
                                .accessibilityHint(field.help ?? "")
                                .accessibilityIdentifier("auth-field-\(field.key)")
                                .id(field.key)
                        }
                    } header: {
                        Text(section.title)
                            .listRowInsets(.horizontal, 0)
                    } footer: {
                        Group {
                            if !section.help.isEmpty { Text(section.help) }
                            if attemptedSubmit, let field = method.form.firstInvalidField(values),
                               section.fields.contains(where: { $0.key == field.key }) {
                                Text(t("agentAuth.requiredField", ["field": field.label]))
                                    .foregroundStyle(Palette.danger)
                            }
                        }
                        .listRowInsets(.horizontal, 0)
                    }
                }
                if let error, !error.isEmpty {
                    Section {
                        Label(error, icon: .warning)
                            .foregroundStyle(Palette.danger)
                    }
                }
                Section {
                    Button {
                        attemptedSubmit = true
                        if let field = method.form.firstInvalidField(values) {
                            withAnimation { scroll.scrollTo(field.key, anchor: .center) }
                            focusedField = field.key
                            return
                        }
                        focusedField = nil
                        onSubmit()
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text(t(working ? "agentAuth.connecting" : "agentAuth.connect"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(Palette.accent)
                    .accessibilityIdentifier("auth-connect")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .disabled(working)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func fieldInput(_ field: DaemonField) -> some View {
        let next = textFields.firstIndex(where: { $0.key == field.key }).flatMap { index in
            textFields.indices.contains(index + 1) ? textFields[index + 1].key : nil
        }
        return AgentAuthFieldInput(field: field, value: Binding(
            get: { values[field.key] ?? field.default ?? "" }, set: { values[field.key] = $0 }
        ), focusedField: $focusedField, nextField: next)
    }
}

/// Shared native inputs for field credentials and interactive authorization codes.
private struct AgentAuthFieldInput: View {
    let field: DaemonField
    @Binding var value: String
    var focusedField: FocusState<String?>.Binding
    var nextField: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        switch field.type {
        case .select:
            if field.presentation == "segmented" && !dynamicTypeSize.isAccessibilitySize {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu)
            }
        case .toggle:
            Toggle(field.label, isOn: Binding(
                get: { value == "true" },
                set: { value = $0 ? "true" : "false" }
            ))
        case .secret, .text, .multiselect:
            TextField(field.label, text: $value, prompt: field.placeholder.map { Text($0) })
                .textContentType(nil)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(field.inputMode == "url" ? .URL : .default)
                .focused(focusedField, equals: field.key)
                .submitLabel(nextField == nil ? .done : .next)
                .onSubmit { focusedField.wrappedValue = nextField }
        }
    }

    private var picker: some View {
        Picker(field.label, selection: $value) {
            ForEach(field.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
    }
}
