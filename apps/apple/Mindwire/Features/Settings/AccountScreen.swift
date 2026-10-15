// Account screen — reflects the shared, observable Oblien session (OblienAuth): signed-in user or
// a sign-in CTA. Reactive, so signing in/out anywhere updates it (and Settings) immediately.
import SwiftUI

struct AccountScreen: View {
    private let creditsURL = URL(string: "https://oblien.com/dashboard/credits")!
    private let purchaseURL = URL(string: "https://oblien.com/dashboard/credits/purchase")!
    private let planURL = URL(string: "https://oblien.com/dashboard/plan")!
    private var auth = OblienAuth.shared
    @State private var loaded = false
    @State private var showLogin = false
    @State private var confirmingSignOut = false
    @State private var overview: CloudAccountOverview?

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
        .sheet(isPresented: $showLogin) {
            OblienLoginSheet { Task { await reload() } }
        }
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
            VStack(spacing: Spacing.sm) {
                avatar(user)
                Text(user?.name ?? "You").font(.title2)
                if let email = user?.email, !email.isEmpty {
                    Text(email).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
        }
        Section {
            if overview?.creationDenial != nil {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label(t("account.noCredits.title"), icon: .warning)
                        .font(.headline)
                        .foregroundStyle(Palette.danger)
                    Text(t("account.noCredits.body"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link(t("account.addCredits"), destination: purchaseURL)
                        .buttonStyle(.glassProminent)
                        .tint(Palette.accent)
                }
                .padding(.vertical, Spacing.xs)
            }
            if let quota = overview?.quota {
                LabeledContent(t("account.plan"), value: quota.planLabel)
                LabeledContent(t("account.workspaces"), value: workspaceUsage(quota))
                LabeledContent(t("account.running"), value: String(quota.runningPoolUsage.count))
            }
            if let balance = overview?.balance {
                LabeledContent(t("account.credits"), value: String(format: "%.2f", balance))
            }
            if let overview {
                LabeledContent(t("account.usage30Days"),
                               value: String(format: "%.2f credits", overview.creditsUsedLast30Days))
            }
        } header: {
            Text(t("account.billing.title"))
        }
        Section {
            if let overview, overview.canUpgradePlan {
                Link(overview.nextPlanName.map { "Upgrade to \($0)" } ?? t("account.upgrade"),
                     destination: planURL)
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
            } else if overview?.quota != nil {
                LabeledContent(t("account.planStatus"), value: t("account.highestPlan"))
            }
            Link(t("account.addCredits"), destination: purchaseURL)
            Link(t("account.viewUsage"), destination: creditsURL)
        }
        Section {
            Button(t("account.signOut"), role: .destructive) { confirmingSignOut = true }
                .foregroundStyle(Palette.danger)
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        Section {
            ContentUnavailableView {
                Label(t("account.title"), icon: .userCircle)
            } description: {
                Text(t("account.notSignedIn"))
            } actions: {
                Button(t("account.signIn")) { showLogin = true }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
            }
        }
    }

    @ViewBuilder private func avatar(_ user: AuthUser?) -> some View {
        if let s = user?.image, let url = URL(string: s) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                Avatar(initial: initial(user), size: 72)
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
        } else {
            Avatar(initial: initial(user), size: 72)
        }
    }

    private func initial(_ user: AuthUser?) -> String {
        (user?.name?.first.map(String.init) ?? "Y").uppercased()
    }

    private func workspaceUsage(_ quota: CloudWorkspaceQuota) -> String {
        guard let maximum = quota.maxWorkspaces else { return "\(quota.currentWorkspaces)" }
        return "\(quota.currentWorkspaces) / \(maximum)"
    }

    private func signOut() {
        Task {
            await BackendFactory.pushService().unregister()
            await OblienAPI.shared.clearToken()
            auth.markSignedOut()
            overview = nil
        }
    }

    private func reload() async {
        await auth.refresh()
        if auth.authenticated {
            overview = await OblienBilling.overview()
        } else {
            overview = nil
        }
        loaded = true
    }
}
