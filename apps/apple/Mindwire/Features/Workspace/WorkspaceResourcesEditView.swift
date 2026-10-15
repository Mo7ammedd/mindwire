import SwiftUI

/// Resize / upgrade a cloud workspace — steppers clamped to `WorkspaceLimits`, applied via
/// `updateResources`. Presented from both the resources section and the live monitor.
struct WorkspaceResourcesEditView: View {
    let current: WorkspaceResources
    let onSave: (WorkspaceResourcePatch) async -> Bool
    var requiresRestart = true
    var errorMessage: () -> String? = { nil }

    @Environment(\.dismiss) private var dismiss
    @State private var cpus: Int
    @State private var memoryGb: Int
    @State private var diskGb: Int
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmation: WorkspaceConfirmation?

    init(current: WorkspaceResources, requiresRestart: Bool = true, errorMessage: @escaping () -> String? = { nil }, onSave: @escaping (WorkspaceResourcePatch) async -> Bool) {
        self.current = current
        self.onSave = onSave
        self.requiresRestart = requiresRestart; self.errorMessage = errorMessage
        _cpus = State(initialValue: max(1, current.cpus))
        _memoryGb = State(initialValue: max(1, Int((Double(current.memoryMb) / 1024).rounded())))
        _diskGb = State(initialValue: max(1, Int(ceil(Double(current.diskMb) / 1024))))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $cpus, in: 1...max(32, current.cpus)) {
                        LabeledContent(t("workspace.cpu"), value: "\(cpus)")
                    }
                    Stepper(value: $memoryGb, in: 1...max(64, Int(ceil(Double(current.memoryMb) / 1024)))) {
                        LabeledContent(t("workspace.memory"), value: "\(memoryGb) GB")
                    }
                    Stepper(value: $diskGb, in: minimumDiskGb...max(1024, minimumDiskGb)) {
                        LabeledContent(t("workspace.disk"), value: "\(diskGb) GB")
                    }
                } footer: {
                    Text(requiresRestart ? "Applying resources may restart the workspace and stop running programs. Disk storage can only grow." : "Resources will apply on the next start. Disk storage can only grow.")
                }
                .disabled(saving)
                if saving { Section { ProgressView("Applying resources…") } }
                if let failure { Section { Text(failure).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(t("workspace.resources.editTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("common.save")) {
                        if requiresRestart {
                            confirmation = .init(title: "Apply Resources & Restart?", message: "Running programs and chats may stop while resources are applied. Files are kept.", actionTitle: "Apply") { await save() }
                        } else { Task { await save() } }
                    }
                    .disabled(saving)
                    .tint(.primary)
                }
            }
        }
        .workspaceConfirmation($confirmation)
    }
    private var minimumDiskGb: Int { max(1, Int(ceil(Double(current.diskMb) / 1024))) }
    private func save() async {
        guard !saving else { return }
        saving = true; failure = nil
        let result = await onSave(.init(cpus: cpus, memoryMb: memoryGb * 1024, diskMb: diskGb * 1024, apply: requiresRestart))
        saving = false
        if result { dismiss() } else { failure = errorMessage() ?? "The resource change could not be completed. Try again." }
    }
}
