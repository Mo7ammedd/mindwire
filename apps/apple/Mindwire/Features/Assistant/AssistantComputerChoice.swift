import SwiftUI

/// Destinations describe presentation only. Both paths use WorkspaceRepository and the
/// existing pairing, Oblien sign-in and cloud creation screens.
enum AssistantComputerDestination {
    case computer, cloud

    var title: String { t(self == .computer ? "assistant.setup.own" : "assistant.setup.cloud") }
    var detail: String { t(self == .computer ? "assistant.setup.own.body" : "assistant.setup.cloud.body") }
    var caption: String { t(self == .computer ? "assistant.setup.own.caption" : "assistant.setup.cloud.caption") }
    var icon: AppIconName { self == .computer ? .laptop : .cloud }

    func includes(_ workspace: Workspace) -> Bool { workspace.isCloud == (self == .cloud) }
}

struct AssistantDestinationCard: View {
    let destination: AssistantComputerDestination
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                heading
                Text(destination.detail).font(.subheadline).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(destination.caption).font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .background(AssistantStyle.surface.opacity(0.45), in: .rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.1)) }
            .contentShape(.rect(cornerRadius: 20))
        }
        .foregroundStyle(.primary).buttonStyle(AssistantPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(destination == .computer ? "assistant.choose.computer" : "assistant.choose.cloud")
    }

    @ViewBuilder private var heading: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    AppIcon(destination.icon, size: 28, decorative: true)
                    Spacer()
                    AppIcon(.chevronRight, size: 16, decorative: true).foregroundStyle(.tertiary)
                }
                Text(destination.title).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 16) {
                AppIcon(destination.icon, size: 28, decorative: true)
                Text(destination.title).font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                AppIcon(.chevronRight, size: 16, decorative: true).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Static device artwork for the connection pages.
/// No remote images, animations, sample conversations or imitation QR codes.
struct AssistantDeviceArtwork: View {
    let destination: AssistantComputerDestination

    var body: some View {
        ZStack {
            if destination == .computer {
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(AssistantStyle.canvas)
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.16), lineWidth: 2) }
                        .overlay { AppLogo(size: 26) }
                        .frame(width: 108, height: 70)
                    Capsule().fill(Color.primary.opacity(0.18)).frame(width: 126, height: 6)
                }
                .offset(x: -12)
            } else {
                RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.05))
                    .frame(width: 88, height: 70).offset(x: -25, y: -12)
                RoundedRectangle(cornerRadius: 20).fill(AssistantStyle.canvas)
                    .frame(width: 88, height: 70)
                    .overlay { AppIcon(.cloud, size: 40).foregroundStyle(Palette.accent) }
                    .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.1)) }
                    .offset(x: -17, y: -3)
            }
            RoundedRectangle(cornerRadius: 10)
                .fill(AssistantStyle.canvas)
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.24), lineWidth: 2) }
                .overlay(alignment: .top) { Capsule().fill(Color.primary.opacity(0.18)).frame(width: 12, height: 3).padding(.top, 5) }
                .overlay { AppIcon(.link, size: 19).foregroundStyle(Palette.accent) }
                .frame(width: 36, height: 64)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                .offset(x: 49, y: 18)
        }
        .frame(width: 160, height: 112)
        .accessibilityHidden(true)
    }
}

/// Inventory appears only after choosing its destination. Cloud prices and provisioning
/// are loaded by NewWorkspaceScreen only when the user chooses to create a computer.
struct AssistantComputerPicker: View {
    let destination: AssistantComputerDestination
    var repository: WorkspaceRepository = .shared
    let onChoose: (Workspace) -> Void
    let onAdd: () -> Void
    @State private var showingLogin = false
    @State private var loading = true

    private var needsSignIn: Bool { destination == .cloud && repository.requiresSignIn }

    var body: some View {
        let computers = repository.all.filter(destination.includes)
        AssistantPage {
            AssistantSetupProgress(step: 0)
            AssistantHeading(title: destination.title, detail: t(needsSignIn ? "assistant.cloud.signIn.body"
                : computers.isEmpty ? (loading ? "assistant.setup.loadingComputers" : "assistant.cloud.create.body") : "assistant.setup.saved.body"))
            if computers.isEmpty {
                AssistantDeviceArtwork(destination: destination)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            if !needsSignIn {
                if loading && computers.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(t("assistant.setup.loadingComputers")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                if !computers.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(computers) { computer in
                            AssistantOption(title: computer.name, detail: "", icon: destination.icon) { onChoose(computer) }
                        }
                    }
                }
                if destination == .cloud, let error = repository.refreshError {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button(t("common.retry")) { Task { await refresh(force: true) } }.tint(.primary)
                            .disabled(loading)
                    }
                }
            }
        } footer: {
            if needsSignIn {
                AssistantPrimaryButton(title: t("assistant.cloud.signIn"), icon: .login) { showingLogin = true }
            } else {
                AssistantPrimaryButton(title: t(destination == .cloud ? "assistant.setup.createCloud" : "assistant.setup.addComputer"),
                                       icon: .plus, action: onAdd)
                    .disabled(loading && computers.isEmpty)
                if destination == .cloud {
                    Text(t("assistant.cloud.costHint")).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle(destination.title).navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh(force: true) }
        .oblienLoginSheet(isPresented: $showingLogin) { Task { await refresh(force: true) } }
    }

    private func refresh(force: Bool = false) async {
        loading = true
        defer { loading = false }
        guard destination == .cloud, !needsSignIn else { return }
        if force { await repository.refresh() }
        else { await repository.refreshIfNeeded() }
    }
}
