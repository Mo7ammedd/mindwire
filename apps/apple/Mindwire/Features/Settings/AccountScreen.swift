// Account screen — reflects the shared, observable Oblien session (MindwireAuth): signed-in user or
// a sign-in CTA. Reactive, so signing in/out anywhere updates it (and Settings) immediately.
import SwiftUI

struct AccountScreen: View {
    private var auth = MindwireAuth.shared
    @State private var loaded = false
    @State private var showLogin = false
    @State private var confirmingSignOut = false
    @State private var computers: [CloudComputer] = []
    @State private var pendingPurchase: CloudComputer?
    @State private var portal: IdentifiedURL?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if !loaded {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if auth.authenticated {
                signedIn(auth.user)
            } else {
                signedOut
            }
        }
        .navigationTitle(t("account.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .mindwireSignIn(isPresented: $showLogin) { Task { await reload() } }
        .sheet(item: $pendingPurchase) { computer in
            CloudPurchaseSheet(computer: computer) { _ in
                pendingPurchase = nil
                Task { await WorkspaceRepository.shared.refresh(); await reload() }
            }
        }
        .sheet(item: $portal) { item in SafariView(url: item.url) }
        .alert(t("account.signOut.title"), isPresented: $confirmingSignOut) {
            Button(t("account.signOut"), role: .destructive) { signOut() }
            Button(t("common.cancel"), role: .cancel) {}
        } message: {
            Text(t("account.signOut.body"))
        }
    }

    // MARK: Signed in

    @ViewBuilder private func signedIn(_ user: AuthUser?) -> some View {
        Section {
            if ApplePlatform.isDesktop {
                HStack(spacing: 12) {
                    avatar(user, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user?.name ?? "You").font(.system(size: 13, weight: .semibold))
                        if let email = user?.email, !email.isEmpty {
                            Text(email).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    switchAccountButton.buttonStyle(.bordered).controlSize(.regular)
                    signOutButton.buttonStyle(.borderless).controlSize(.regular)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: Spacing.sm) {
                    avatar(user)
                    Text(user?.name ?? "You").font(.title2)
                    if let email = user?.email, !email.isEmpty {
                        Text(email).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                switchAccountButton
                signOutButton
            }
        }
        Section {
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.secondary) }
            if computers.isEmpty { Text("Each Cloud Computer has its own monthly subscription. Your own computers remain free.").foregroundStyle(.secondary) }
            ForEach(computers) { computer in
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    LabeledContent(computer.name, value: computer.state.replacingOccurrences(of: "_", with: " ").capitalized)
                    Text("\(computer.plan.name) · \(computer.plan.monthlyPrice)").font(.footnote).foregroundStyle(.secondary)
                    if let subscription = computer.subscription {
                        Text(subscription.cancelAtPeriodEnd ? "Renewal is stopped. Your paid period is preserved." : "Monthly subscription")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Manage billing") {
                            Task {
                                do { portal = IdentifiedURL(url: try await CloudComputers.billingPortal(computer.id)) }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                    } else {
                        Button("Continue checkout") {
                            Task {
                                do { pendingPurchase = try await CloudComputers.checkout(computer.id) }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            Link("Open Mindwire Console", destination: URL(string: AppConstants.mindwireServicesBase + "/computers")!)
        } header: { Text("Cloud Computers") }
        if SessionToken.get() != nil {
            Section {
                Button("Connect previous cloud account") {
                    Task {
                        do { try await MindwireAPI.shared.linkPreviousAccount(); await BackendFactory.pushService().refreshRegistration(); await WorkspaceRepository.shared.refresh(); errorMessage = nil }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            } footer: { Text("Connect your previous account to keep its computers, files and paid terms. Nothing is moved or deleted.") }
        }
    }

    private var switchAccountButton: some View {
        Button("Switch account") { showLogin = true }
            .tint(.primary).accessibilityIdentifier("account.switch")
    }

    private var signOutButton: some View {
        Button(t("account.signOut"), role: .destructive) { confirmingSignOut = true }
            .foregroundStyle(Palette.danger).accessibilityIdentifier("account.signOut")
    }

    // MARK: Signed out

    private var signedOut: some View {
        Section {
            MindwireSignInPrompt(bodyKey: "account.signIn.body") {
                showLogin = true
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private func avatar(_ user: AuthUser?, size: CGFloat = 72) -> some View {
        if let s = user?.image, let url = URL(string: s) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                Avatar(initial: initial(user), size: size)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            Avatar(initial: initial(user), size: size)
        }
    }

    private func initial(_ user: AuthUser?) -> String {
        (user?.name?.first.map(String.init) ?? "Y").uppercased()
    }

    private func signOut() {
        Task {
            await BackendFactory.pushService().unregister()
            do { try await MindwireAPI.shared.signOut() }
            catch { errorMessage = "Could not sign out. Check your connection and retry."; return }
            auth.markSignedOut()
            computers = []
        }
    }

    private func reload() async {
        await auth.refresh()
        if auth.authenticated {
            do { computers = try await CloudComputers.list(); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        } else {
            computers = []
        }
        loaded = true
    }
}
