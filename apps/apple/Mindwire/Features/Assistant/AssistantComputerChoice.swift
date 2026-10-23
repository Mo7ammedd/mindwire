import SwiftUI

/// Destinations describe presentation only. Both paths use WorkspaceRepository and the
/// existing pairing, Mindwire sign-in and cloud creation screens.
enum AssistantComputerDestination {
    case computer, cloud

    var title: String { t(self == .computer ? "assistant.setup.own" : "assistant.setup.cloud") }
    var detail: String { t(self == .computer ? "assistant.setup.own.body" : "assistant.setup.cloud.body") }
    var icon: AppIconName { self == .computer ? .laptop : .cloud }

    func includes(_ workspace: Workspace) -> Bool { workspace.isCloud == (self == .cloud) }
}

struct AssistantDestinationCard: View {
    let destination: AssistantComputerDestination
    let action: () -> Void
    @Environment(\.assistantTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                if !dynamicTypeSize.isAccessibilitySize {
                    AssistantDestinationArtwork(destination: destination)
                        .frame(width: 68, height: 88)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(destination.title).font(theme.font(22, weight: .medium, relativeTo: .title2)).tracking(-0.5)
                        Spacer(minLength: 4)
                        AppIcon(.arrowUpRight, size: 18, decorative: true).foregroundStyle(theme.muted)
                    }
                    Text(destination.detail).font(theme.font(15, relativeTo: .subheadline)).foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(AssistantChoiceStyle(radius: 24))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(destination == .computer ? "assistant.choose.computer" : "assistant.choose.cloud")
    }
}

private struct AssistantDestinationArtwork: View {
    let destination: AssistantComputerDestination
    @Environment(\.assistantTheme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(destination == .computer ? theme.peachSoft : theme.blueSoft)
                .frame(width: 68, height: 76)
            AppIcon(destination.icon, size: 36, decorative: true)
                .foregroundStyle(theme.ink.opacity(0.7)).offset(y: -9)
            AssistantBotAvatar(botId: "destination", icon: destination == .computer ? "peach-bean" : "blue-robot", size: 35)
                .rotationEffect(.degrees(destination == .computer ? -10 : 8)).offset(x: 17, y: 25)
        }
        .accessibilityHidden(true)
    }
}

/// Static device artwork for the connection pages.
/// No remote images, animations, sample conversations or imitation QR codes.
struct AssistantDeviceArtwork: View {
    let destination: AssistantComputerDestination
    var size: CGFloat = 160
    @Environment(\.assistantTheme) private var theme

    var body: some View {
        ZStack {
            if destination == .computer {
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(theme.canvas)
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.16), lineWidth: 2) }
                        .overlay { AssistantBotAvatar(botId: "computer", icon: "peach-pebble", size: 38) }
                        .frame(width: 108, height: 70)
                    Capsule().fill(Color.primary.opacity(0.18)).frame(width: 126, height: 6)
                }
                .offset(x: -12)
            } else {
                RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.05))
                    .frame(width: 88, height: 70).offset(x: -25, y: -12)
                RoundedRectangle(cornerRadius: 20).fill(theme.canvas)
                    .frame(width: 88, height: 70)
                    .overlay { AssistantBotAvatar(botId: "cloud", icon: "blue-cloud", size: 44) }
                    .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.1)) }
                    .offset(x: -17, y: -3)
            }
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.canvas)
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.24), lineWidth: 2) }
                .overlay(alignment: .top) { Capsule().fill(Color.primary.opacity(0.18)).frame(width: 12, height: 3).padding(.top, 5) }
                .overlay { AppIcon(.link, size: 19).foregroundStyle(Palette.accent) }
                .frame(width: 36, height: 64)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                .offset(x: 49, y: 18)
        }
        .frame(width: 160, height: 112)
        .scaleEffect(size / 160)
        .frame(width: size, height: size * 0.7)
        .accessibilityHidden(true)
    }
}

/// A small illustration of the desktop action the user needs, using the website's
/// product-window treatment. This is artwork, not a second pairing implementation.
struct AssistantPairingArtwork: View {
    @Environment(\.assistantTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in Circle().fill(theme.line).frame(width: 6, height: 6) }
                Spacer()
                Text("Mindwire").font(theme.font(12, weight: .medium, relativeTo: .caption))
                Spacer()
                Color.clear.frame(width: 28, height: 6)
            }
            .foregroundStyle(theme.muted).padding(14)
            Rectangle().fill(theme.line).frame(height: 1)
            HStack(spacing: 20) {
                AssistantBotAvatar(botId: "pairing-guide", icon: "peach-bean", size: 66)
                    .rotationEffect(.degrees(-8))
                VStack(alignment: .leading, spacing: 12) {
                    Capsule().fill(theme.line).frame(width: 76, height: 5)
                    HStack(spacing: 7) {
                        AppIcon(.scan, size: 16, decorative: true)
                        Text(t("onboarding.pair.menu"))
                            .font(theme.font(13, weight: .medium, relativeTo: .caption))
                    }
                    .foregroundStyle(theme.peach)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(theme.peachSoft, in: .rect(cornerRadius: 12))
                    Capsule().fill(theme.line).frame(width: 106, height: 5)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 26)
        }
        .background(theme.surface, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(theme.line, lineWidth: 1) }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(theme.subtle, in: .rect(cornerRadius: 30))
        .frame(maxWidth: 350).frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// Inventory appears only after choosing its destination. Account resolution and a successful
/// inventory read precede cloud creation; the shared services still own sign-in and computers.
struct AssistantComputerPicker: View {
    let destination: AssistantComputerDestination
    var repository: WorkspaceRepository = .shared
    let onChoose: (Workspace) -> Void
    let onAdd: () -> Void
    @Environment(\.stores) private var stores
    @State private var loading = true
    @State private var inventoryAccountID: String?
    @State private var loadError: String?
    @State private var switchingAccount = false

    private var auth: MindwireAuth { .shared }
    private var isCloud: Bool { destination == .cloud }
    private var needsSignIn: Bool { isCloud && repository.requiresSignIn }
    private var computers: [Workspace] { repository.all.filter(destination.includes) }
    private var inventoryReady: Bool {
        !loading && loadError == nil && auth.authenticated && auth.user?.id != nil
            && inventoryAccountID == auth.user?.id
    }

    private var title: String {
        if !isCloud { return t("onboarding.computer.chooseSaved") }
        if needsSignIn { return t("onboarding.cloud.signIn.title") }
        if inventoryReady {
            return t(computers.isEmpty ? "onboarding.cloud.empty.title" : "onboarding.computer.chooseSaved")
        }
        return destination.title
    }

    private var detail: String {
        if needsSignIn { return t("onboarding.cloud.signIn.body") }
        if isCloud && !inventoryReady { return "" }
        if isCloud && computers.isEmpty { return t("onboarding.cloud.empty.body") }
        return t("assistant.setup.saved.body")
    }

    var body: some View {
        AssistantPage {
            AssistantSetupProgress(step: 0)
            AssistantHeading(title: title, detail: detail)
            if isCloud && auth.authenticated {
                HStack(spacing: 10) {
                    AppIcon(.userCircle, size: 20, decorative: true).foregroundStyle(.secondary)
                    Text(auth.user?.email ?? auth.user?.name ?? t("account.title"))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(t("onboarding.cloud.switchAccount")) { switchingAccount = true }
                        .font(.footnote.weight(.medium)).buttonStyle(.plain).tint(.primary)
                        .accessibilityIdentifier("onboarding.cloud.switchAccount")
                }
                .padding(.vertical, 10)
            }
            if needsSignIn || inventoryReady && computers.isEmpty {
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
                    .accessibilityIdentifier("onboarding.computers.loading")
                }
                if !computers.isEmpty && (!isCloud || auth.authenticated) {
                    VStack(spacing: 12) {
                        ForEach(computers) { computer in
                            AssistantOption(title: computer.name, detail: t("onboarding.computer.verify"), icon: icon(for: computer)) { onChoose(computer) }
                        }
                    }
                }
                if let loadError {
                    AssistantSetupIssue(message: loadError, retry: { Task { await refresh(force: true) } }).disabled(loading)
                }
            }
        } footer: {
            if needsSignIn {
                // The shared handoff updates MindwireAuth. The account-scoped task below then
                // loads this account's inventory, including sign-ins started elsewhere.
                CloudSignIn(onboarding: true)
            } else if isCloud {
                // Existing customers choose their saved computer. Creation is
                // offered only after this account's inventory confirms none exist.
                if inventoryReady && computers.isEmpty {
                    AssistantPrimaryButton(title: t("assistant.setup.createCloud"), icon: .plus, action: onAdd)
                        .accessibilityIdentifier("onboarding.cloud.create")
                    Text(t("assistant.cloud.costHint")).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                AssistantPrimaryButton(title: t("assistant.setup.addComputer"), icon: .plus, action: onAdd)
            }
        }
        .navigationTitle(destination.title).navigationBarTitleDisplayMode(.inline)
        .task(id: isCloud ? auth.user?.id : nil) { await refresh() }
        .refreshable { await refresh(force: true) }
        .mindwireSignIn(isPresented: $switchingAccount)
    }

    private func icon(for computer: Workspace) -> AppIconName {
        if let serverID = computer.runtime.serverId, stores.connections.get(serverID)?.remote != nil { return .server }
        return destination.icon
    }

    private func refresh(force: Bool = false) async {
        loading = true
        loadError = nil
        inventoryAccountID = nil
        defer { if !Task.isCancelled { loading = false } }
        guard isCloud else { return }
        do {
            guard try await auth.check(force: force) else { return }
            try Task.checkCancellation()
            guard let accountID = auth.user?.id else {
                throw BackendError.message(t("assistant.cloud.signIn.body"))
            }
            // A cached empty list from before sign-in cannot stand in for this account's inventory.
            // Concurrent sign-in/startup refreshes join the repository's existing request.
            await repository.refresh()
            try Task.checkCancellation()
            guard auth.user?.id == accountID else { return }
            if let error = repository.refreshError { loadError = error }
            else { inventoryAccountID = accountID }
        } catch {
            if !error.isRequestCancellation { loadError = error.localizedDescription }
        }
    }
}
