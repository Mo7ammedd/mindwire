import SwiftUI

struct NotificationConnectionSheet: View {
    let onSignIn: () -> Void
    let onLater: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HStack(spacing: 12) {
                        AgentLogo(id: .codex, size: 26)
                        AgentLogo(id: .claudeCode, size: 26)
                        AppIcon(.chevronRight).font(.caption).foregroundStyle(.tertiary)
                        OblienMark(size: 42)
                    }
                    .accessibilityHidden(true)
                    VStack(spacing: 10) {
                        Text("Know when your agent needs you")
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text("Sign in to Oblien for alerts when work finishes, an agent needs your answer, or a turn fails.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("Works with your Mac, servers and cloud workspaces.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 12) {
                        Button(action: onSignIn) {
                            Text("Sign in to Oblien").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent).controlSize(.large).tint(Palette.accent)
                        .accessibilityIdentifier("notification-intro-sign-in")
                        Button("Remind me later", action: onLater)
                            .tint(.primary)
                            .accessibilityIdentifier("notification-intro-later")
                    }
                    Text("Optional. Your computers and SSH workspaces work without signing in.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Stay connected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Not now", action: onCancel).tint(.primary)
                        .accessibilityIdentifier("notification-intro-cancel")
                }
            }
        }
        .presentationDetents([.height(470), .large])
        .presentationDragIndicator(.visible)
    }
}
