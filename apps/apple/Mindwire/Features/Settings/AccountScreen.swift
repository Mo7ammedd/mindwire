// Account screen — reflects the shared, observable Mindwire session: signed-in user or
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
    @State private var showDeletion = false
    @State private var deletionUserID: String?
    @State private var deletionPending = false
    @State private var deletionCompleted = false

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
        .sheet(isPresented: $showDeletion, onDismiss: { Task { await reload() } }) {
            if let userID = deletionUserID {
                AccountDeletionSheet(userID: userID) {
                    showDeletion = false
                    computers = []
                    deletionPending = false
                    auth.markSignedOut()
                    deletionCompleted = true
                }
            }
        }
        .alert("Account deleted", isPresented: $deletionCompleted) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text("Your Mindwire account has been deleted. Your personal computers and separate AI accounts are unchanged.") }
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
        if !deletionPending { Section {
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
        } header: { Text("Cloud Computers") } }
        if SessionToken.get() != nil && !deletionPending {
            Section {
                Button("Connect previous cloud account") {
                    Task {
                        do { try await MindwireAPI.shared.linkPreviousAccount(); await BackendFactory.pushService().refreshRegistration(); await WorkspaceRepository.shared.refresh(); errorMessage = nil }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            } footer: { Text("Connect your previous account to keep its computers, files and paid terms. Nothing is moved or deleted.") }
        }
        Section {
            Button(deletionPending ? "View deletion status" : "Delete account", role: .destructive) {
                deletionUserID = auth.user?.id
                showDeletion = true
            }
            .accessibilityIdentifier("account.delete")
        } footer: {
            Text(deletionPending ? "Your account is being deleted. Cleanup continues automatically." : "Permanently delete your Mindwire account and Cloud data.")
        }
    }

    private var switchAccountButton: some View {
        Button("Switch account") { showLogin = true }
            .disabled(deletionPending)
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
            do {
                deletionPending = try await MindwireAPI.shared.accountDeletionOptions().status == "pending"
                if deletionPending { computers = [] }
                else { computers = try await CloudComputers.list() }
                errorMessage = nil
            }
            catch { errorMessage = error.localizedDescription }
        } else {
            computers = []
            deletionPending = false
        }
        loaded = true
    }
}

/// Both platforms use the same account API and lifecycle; only the presentation
/// size changes. No provider credentials or personal-computer stores are touched.
private struct AccountDeletionSheet: View {
    let userID: String
    let onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options: AccountDeletionOptions?
    @State private var progress: AccountDeletionProgress?
    @State private var confirmation = ""
    @State private var password = ""
    @State private var receipt: String?
    @State private var busy = false
    @State private var showLogin = false
    @State private var error: String?

    private var needsSignIn: Bool { options?.hasPassword == false && options?.needsSignIn == true }

    var body: some View {
        NavigationStack {
            Form {
                if let progress {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            ProgressView()
                            Text(progress.message).font(.subheadline)
                        }
                        .padding(.vertical, 8)
                    } header: { Text("Deleting account") }
                } else if let options {
                    Section {
                        Text("Your profile, sessions, saved credentials and notification registrations will be deleted.")
                        Text("Mindwire Cloud renewals will stop. Your Cloud Computers, files, backups and published apps will be permanently removed.")
                        Text("Your personal computers and separate AI or Oblien accounts stay yours. Billing records required by law may be retained.")
                    } header: { Text("This is permanent") } footer: { Text("Save anything you want to keep before continuing.") }
                    if needsSignIn {
                        Section {
                            Button("Sign in again") { showLogin = true }
                                .tint(.primary)
                        } footer: { Text("Verify your identity, then return here to confirm deletion.") }
                    } else {
                        Section {
                            if options.hasPassword {
                                SecureField("Mindwire password", text: $password)
                                    .textContentType(.password)
                            }
                            TextField("Type DELETE to confirm", text: $confirmation)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        } header: { Text("Confirm deletion") }
                        Section {
                            Button(role: .destructive) { Task { await requestDeletion() } } label: {
                                HStack {
                                    Spacer()
                                    if busy { ProgressView() }
                                    Text("Permanently delete account")
                                    Spacer()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(busy || confirmation != "DELETE" || (options.hasPassword && password.isEmpty))
                        } footer: {
                            Text("Cleanup continues if you close this screen. It usually takes a few minutes; Cloud cleanup can take longer.")
                        }
                    }
                } else {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(Palette.danger)
                        if options == nil { Button("Retry") { Task { await load() } }.tint(.primary) }
                    }
                }
            }
            .disabled(busy)
            .navigationTitle(progress == nil ? "Delete account" : "Account deletion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(progress == nil ? t("common.cancel") : t("common.done")) { dismiss() }
                        .tint(.primary)
                        .disabled(busy)
                }
            }
            .task { await load() }
            .task(id: receipt) { await followProgress() }
            .mindwireSignIn(isPresented: $showLogin) { Task { await load() } }
        }
        .interactiveDismissDisabled(busy)
        .frame(minWidth: ApplePlatform.isDesktop ? 480 : nil, minHeight: ApplePlatform.isDesktop ? 520 : nil)
    }

    private func load() async {
        do {
            await MindwireAuth.shared.refresh()
            guard MindwireAuth.shared.user?.id == userID else {
                options = nil
                error = "You signed in to a different account. Return to the account you want to delete."
                return
            }
            let value = try await MindwireAPI.shared.accountDeletionOptions()
            options = value
            error = nil
            if value.status == "pending" { await requestDeletion() }
        } catch { self.error = error.localizedDescription }
    }

    private func requestDeletion() async {
        guard !busy, MindwireAuth.shared.user?.id == userID else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await MindwireAPI.shared.deleteAccount(expectedUserID: userID, password: password)
            password = ""; confirmation = ""
            progress = value; receipt = value.receipt
        } catch { self.error = error.localizedDescription }
    }

    private func followProgress() async {
        guard let receipt else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(3))
                let value = try await MindwireAPI.shared.accountDeletionProgress(receipt: receipt)
                try Task.checkCancellation()
                if value.status == "deleted" {
                    await MindwireAPI.shared.clearToken()
                    onDeleted()
                    return
                }
                progress = value; error = nil
            } catch is CancellationError { return }
            catch { self.error = "Progress is temporarily unavailable. Cleanup continues automatically." }
        }
    }
}
