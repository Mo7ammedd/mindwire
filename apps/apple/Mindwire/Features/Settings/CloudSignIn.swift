import SwiftUI

/// Onboarding keeps its own first action; every entry point uses the same browser handoff.
struct CloudSignIn: View {
    var onboarding = false
    let onDone: () -> Void
    @State private var signingIn = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            if onboarding {
                AssistantPrimaryButton(title: t("assistant.cloud.signIn"), icon: .login,
                                       busy: signingIn) { signingIn = true }
                    .accessibilityIdentifier("onboarding.cloud.signIn")
            } else {
                Button { signingIn = true } label: {
                    Label(t("login.cta"), icon: .login).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large).tint(Palette.accent)
                .disabled(signingIn)
            }
            Text(t("login.legal"))
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .mindwireSignIn(isPresented: $signingIn, onSignedIn: onDone)
    }
}

extension View {
    /// The first sign-in action opens Safari directly, without another confirmation screen.
    func mindwireSignIn(isPresented: Binding<Bool>, onSignedIn: @escaping () -> Void = {}) -> some View {
        modifier(MindwireSignInPresentation(isPresented: isPresented, onSignedIn: onSignedIn))
    }
}

private struct MindwireSignInPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let onSignedIn: () -> Void
    @State private var authSession: IdentifiedURL?
    @State private var starting = false
    @State private var checking = false
    @State private var login: MindwireAPI.DeviceLogin?
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var completed = false
    @State private var browserClosed = false
    @State private var attempt = UUID()

    func body(content: Content) -> some View {
        content
            .overlay {
                if starting || checking {
                    ZStack {
                        Color.primary.opacity(0.04).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView(starting ? "Opening sign-in…" : "Finishing sign-in…")
                            Button(t("common.cancel")) { isPresented = false; cancel() }.tint(.primary)
                        }
                        .padding(24).background(.regularMaterial, in: .rect(cornerRadius: 22))
                    }
                    .accessibilityIdentifier("mindwire.signIn.progress")
                }
            }
            .sheet(item: $authSession, onDismiss: onSafariDismiss) { item in
                SafariView(url: item.url) { authSession = nil }
                    .safeAreaInset(edge: .top) {
                        if let code = login?.userCode {
                            Text("Confirm code \(code)").font(.footnote)
                                .frame(maxWidth: .infinity).padding(10).background(.bar)
                        }
                    }
            }
            .task(id: isPresented) {
                if isPresented { await start() }
                else { cancel() }
            }
            .onDisappear { isPresented = false; cancel() }
            .alert(t("auth.error.title"), isPresented: Binding(
                get: { error != nil && !isPresented && authSession == nil && !starting && !checking },
                set: { if !$0 { error = nil } }
            )) {
                Button(t("common.retry")) { isPresented = true }
                Button(t("common.cancel"), role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func start() async {
        guard !starting, !checking, authSession == nil else { return }
        cancel()
        let expected = attempt
        starting = true; error = nil
        defer { if attempt == expected { starting = false } }
        do {
            let session = try await MindwireAPI.shared.createAuthSession()
            guard !Task.isCancelled, attempt == expected else { return }
            login = session
            authSession = IdentifiedURL(url: session.verificationURIComplete)
            beginPolling(session, expected: expected)
        } catch {
            guard !Task.isCancelled, attempt == expected else { return }
            self.error = error.localizedDescription
            isPresented = false
        }
    }

    /// Device approval exchanges a one-time code for the native account session.
    private func beginPolling(_ login: MindwireAPI.DeviceLogin, expected: UUID) {
        pollTask?.cancel()
        pollTask = Task {
            var interval = max(5, login.interval)
            let deadline = Date().addingTimeInterval(Double(login.expiresIn))
            while !Task.isCancelled && Date() < deadline {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                do {
                    let status = try await MindwireAPI.shared.pollAuthSession(login.deviceCode)
                    guard attempt == expected else { return }
                    switch status {
                    case .authenticated:
                        completed = true
                        if browserClosed { finish(expected: expected) }
                        else { authSession = nil }
                        return
                    case .expired:
                        guard !Task.isCancelled else { return }
                        self.login = nil; authSession = nil; error = t("login.expired")
                        if browserClosed { checking = false; isPresented = false }
                        return
                    case .slowDown: interval += 5
                    case .pending:
                        if browserClosed { checking = false; isPresented = false; return }
                    }
                } catch {
                    // Keep the same approval code during short network interruptions.
                    guard !Task.isCancelled, attempt == expected else { return }
                    if browserClosed {
                        self.error = "Sign-in could not finish. Check your connection and try again."
                        checking = false; isPresented = false
                        return
                    }
                }
            }
            if !Task.isCancelled, attempt == expected {
                self.login = nil; authSession = nil; error = t("login.expired")
                if browserClosed { checking = false; isPresented = false }
            }
        }
    }

    /// Finish after Safari's dismissal animation, so a pending next screen can open safely.
    private func onSafariDismiss() {
        guard isPresented else { return }
        browserClosed = true
        if completed { finish(expected: attempt); return }
        guard login != nil else { isPresented = false; return }
        // Reuse the scheduled poll, including its server-provided interval. A
        // second immediate exchange could consume the same code or be throttled.
        checking = true
    }

    private func finish(expected: UUID) {
        guard attempt == expected, isPresented else { return }
        checking = false
        isPresented = false
        MindwireAuth.shared.markSignedIn()
        onSignedIn()
    }

    private func cancel() {
        attempt = UUID()
        pollTask?.cancel(); pollTask = nil
        login = nil; authSession = nil
        completed = false; browserClosed = false; starting = false; checking = false
    }
}
