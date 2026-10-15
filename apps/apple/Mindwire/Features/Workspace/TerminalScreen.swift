import SwiftUI
import UIKit

/// Full-screen native tabbed terminal, reusable for any host: a workspace or a server (over SSH).
/// The caller supplies a `title` and a `makeProvider` factory. On open the provider reopens any
/// existing terminals (cloud restores its PTYs with scrollback over one shared socket) or starts a
/// fresh one; "+" adds a tab, the tab "×" kills that PTY, and dismissing detaches but leaves cloud
/// PTYs alive for next time. A dark nav bar carries Done + a settings menu (text size + theme) +
/// new-tab; a tab strip appears once there's more than one terminal. SwiftTerm renders the PTY.
struct TerminalScreen: View {
    let title: String
    var startsNewSessionIfEmpty = true
    let makeProvider: () -> TerminalProvider

    @Environment(\.dismiss) private var dismiss
    @AppStorage("mindwire.terminal.theme") private var themeId = "oblien-dark"
    @AppStorage("mindwire.terminal.fontSize") private var fontSizeKey = "medium"

    @State private var provider: TerminalProvider?
    @State private var tabs: [TerminalTab] = []
    @State private var activeId: UUID?
    @State private var restoring = true
    @State private var closingTab: UUID?

    private var theme: TerminalTheme { TerminalTheme.with(id: themeId) }
    private var fontSize: CGFloat { TerminalFontSize.points(for: fontSizeKey) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: theme.background).ignoresSafeArea()

                ZStack {
                    ForEach(tabs) { tab in
                        WorkspaceTerminalView(session: tab.session, theme: theme, fontSize: fontSize, isActive: tab.id == activeId)
                            .opacity(tab.id == activeId ? 1 : 0)
                            .allowsHitTesting(tab.id == activeId)
                    }
                }
                .padding(.horizontal, Spacing.sm)

                if restoring && tabs.isEmpty {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(uiColor: theme.background), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if tabs.count > 1 { tabStrip }
            }
        }
        .task { await bootstrap() }
        .alert(t("workspace.terminal.closeConfirm"), isPresented: Binding(
            get: { closingTab != nil }, set: { if !$0 { closingTab = nil } }
        )) {
            Button(t("workspace.terminal.close"), role: .destructive) {
                if let tab = tabs.first(where: { $0.id == closingTab }) { closeTab(tab) }
                closingTab = nil
            }
            Button(t("common.cancel"), role: .cancel) { closingTab = nil }
        } message: { Text(t("workspace.terminal.closeBody")) }
        .onDisappear {
            tabs.forEach { $0.session.stop() }   // detach (cloud PTYs stay alive for next open)
            provider?.teardown()                 // drop the shared socket
        }
    }

    // MARK: - Navigation bar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        AppToolbarItem(placement: .topBarLeading) {
            Button(t("common.done")) {
                // Drop the terminal keyboard before the cover dismisses (it lingers otherwise).
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                dismiss()
            }
        }
        AppToolbarItem(placement: .topBarTrailing) {
            AppMenu {
                if let activeId {
                    DestructiveButton(t("workspace.terminal.close"), icon: .xCircle) {
                        closingTab = activeId
                    }
                }
                Picker(t("workspace.terminal.size"), selection: $fontSizeKey) {
                    ForEach(TerminalFontSize.allCases) { size in
                        Text(t("workspace.terminal.size.\(size.rawValue)")).tag(size.rawValue)
                    }
                }
                Picker(t("workspace.terminal.theme"), selection: $themeId) {
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
            } label: {
                AppIcon(.moreCircle)
            }
        }
        AppToolbarItem(placement: .topBarTrailing) {
            Button { addTab() } label: { AppIcon(.plus) }
                .disabled(provider == nil)
        }
    }

    // MARK: - Tab strip (only when more than one terminal)

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(tabs) { tabChip($0) }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
        .background(Color(uiColor: theme.background))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func tabChip(_ tab: TerminalTab) -> some View {
        let active = tab.id == activeId
        return HStack(spacing: 6) {
            AppIcon(Icon.terminal).font(.caption2)
            Button { activeId = tab.id } label: {
                Text(tab.title).lineLimit(1)
            }
            .buttonStyle(.plain)
            Button { closingTab = tab.id } label: {
                AppIcon(.close).font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
        .foregroundStyle(active ? .white : Color(white: 0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            active ? Color.white.opacity(0.16) : Color.white.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    // MARK: - Tabs

    /// Build the provider once, then reopen any existing terminals (cloud) or start a fresh one.
    private func bootstrap() async {
        guard provider == nil else { return }
        let p = makeProvider()
        provider = p
        let restored = await p.restoreSessions()
        if restored.isEmpty {
            if startsNewSessionIfEmpty { addTab() }
            else { dismiss() }
        } else {
            for (i, session) in restored.enumerated() {
                tabs.append(TerminalTab(title: t("workspace.terminal.tab", ["n": "\(i + 1)"]), session: session))
            }
            activeId = tabs.first?.id
        }
        restoring = false
    }

    private func addTab() {
        guard let provider else { return }
        let tab = TerminalTab(
            title: t("workspace.terminal.tab", ["n": "\(tabs.count + 1)"]),
            session: provider.newSession()
        )
        tabs.append(tab)
        activeId = tab.id
    }

    private func closeTab(_ tab: TerminalTab) {
        tab.session.kill()   // closing a tab terminates its PTY (cloud: DELETE /terminals/:id)
        tabs.removeAll { $0.id == tab.id }
        if activeId == tab.id { activeId = tabs.last?.id }
        if tabs.isEmpty { dismiss() }
    }
}

/// One terminal tab — its own session (and thus its own SwiftTerm view + scrollback).
private struct TerminalTab: Identifiable {
    let id = UUID()
    var title: String
    let session: TerminalSession
}
