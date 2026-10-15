// Oblien sign-in — exactly how the dashboard does it: ask the API for a hosted-login session,
// open auth.oblien.com/<id> in an in-app Safari (the page handles email/password, 2FA, and every
// OAuth provider), and poll until the session attaches a user to our token. One button, no
// in-app password fields or OAuth SDKs. Used by the optional cloud login modal.
import SwiftUI

struct CloudSignIn: View {
    let onDone: () -> Void

    @State private var authSession: IdentifiedURL?
    @State private var starting = false
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var completed = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Button(action: start) {
                HStack {
                    Spacer()
                    if starting {
                        ProgressView().tint(Palette.onAccent)
                    } else {
                        Label(t("login.cta"), icon: .login)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(Palette.accent)
            .disabled(starting)

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Text(t("login.legal"))
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .sheet(item: $authSession, onDismiss: onSafariDismiss) { item in
            SafariView(url: item.url) { authSession = nil }
                .ignoresSafeArea()
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: Actions

    private func start() {
        guard !starting else { return }
        starting = true
        error = nil
        Task {
            do {
                let session = try await OblienAPI.shared.createAuthSession()
                authSession = IdentifiedURL(url: session.url)
                beginPolling(session.id)
            } catch let err {
                error = err.localizedDescription
            }
            starting = false
        }
    }

    /// Poll the hosted session; on success auto-close Safari and finish.
    private func beginPolling(_ id: String) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                if Task.isCancelled { return }
                switch await OblienAPI.shared.pollAuthSession(id) {
                case .authenticated:
                    authSession = nil
                    finish()
                    return
                case .expired:
                    authSession = nil
                    error = t("login.expired")
                    return
                case .pending:
                    continue
                }
            }
        }
    }

    /// The user closed Safari — stop polling, but they may have logged in right before closing.
    private func onSafariDismiss() {
        pollTask?.cancel()
        Task { if await OblienLogin.isSignedIn() { finish() } }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        OblienAuth.shared.markSignedIn()
        onDone()
    }
}
