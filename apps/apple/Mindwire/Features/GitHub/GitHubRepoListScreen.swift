import SwiftUI

/// A repository row — name + privacy, description, and the language dot + stars + updated line.
/// Shared by the clone picker (`GitHubReposScreen`) and the installation browser.
struct GitHubRepoRow: View {
    let repo: GitHubRepo

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(repo.name).font(.body.weight(.semibold)).lineLimit(1)
                if repo.isPrivate {
                    AppIcon(.lock).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let d = repo.description, !d.isEmpty {
                Text(d).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: Spacing.md) {
                if let lang = repo.language {
                    metaItem { Circle().fill(Self.langColor(lang)).frame(width: 9, height: 9) } text: { Text(lang) }
                }
                if repo.stars > 0 {
                    metaItem { AppIcon(.star) } text: { Text(Self.formatStars(repo.stars)) }
                }
                if let updated = repo.updatedAt, let rel = Self.relative(updated) {
                    metaItem { AppIcon(.clock) } text: { Text(rel) }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, Spacing.xs)
    }

    /// One metadata chip: small leading glyph + label, tight spacing.
    private func metaItem<Icon: View, Label: View>(@ViewBuilder icon: () -> Icon,
                                                    @ViewBuilder text: () -> Label) -> some View {
        HStack(spacing: 4) {
            icon().font(.caption2)
            text()
        }
    }

    static func formatStars(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000.0) : "\(n)"
    }

    /// Compact relative time from an ISO-8601 timestamp ("2d ago", "3w ago"). Returns the input
    /// unchanged if it's already relative (mock data) and nil only when empty.
    static func relative(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        guard let date = RelativeTime.date(s) else { return s }
        return RelativeTime.text(date)
    }

    /// GitHub-ish language dot colors (a tiny data accent, like the real repo list).
    static func langColor(_ lang: String) -> Color {
        switch lang.lowercased() {
        case "swift": return Color(red: 0.94, green: 0.32, blue: 0.22)
        case "typescript", "ts": return Color(red: 0.18, green: 0.40, blue: 0.71)
        case "javascript", "js": return Color(red: 0.95, green: 0.85, blue: 0.27)
        case "go": return Color(red: 0.00, green: 0.68, blue: 0.85)
        case "python": return Color(red: 0.21, green: 0.49, blue: 0.70)
        case "rust": return Color(red: 0.87, green: 0.42, blue: 0.26)
        case "hcl": return Color(red: 0.51, green: 0.30, blue: 0.83)
        case "css": return Color(red: 0.33, green: 0.22, blue: 0.74)
        case "ruby": return Color(red: 0.44, green: 0.05, blue: 0.05)
        case "java", "kotlin": return Color(red: 0.69, green: 0.36, blue: 0.00)
        default: return Color.secondary
        }
    }
}

/// Read-only browse of one installation's repositories (Settings → GitHub → tap an installation).
/// Reuses `GitHubRepoRow`; tapping a repo opens it on github.com.
struct GitHubRepoListScreen: View {
    let account: GitHubAccount
    let owner: GitHubOwner

    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var repos: [GitHubRepo] = []
    @State private var loading = true
    @State private var query = ""
    @State private var actionRepo: GitHubRepo?     // tapped repo → bottom action sheet
    @State private var projectRepo: GitHubRepo?     // → new-project sheet, pre-seeded
    @State private var pendingCreate: GitHubRepo?   // "create project" chosen; presented after the sheet closes

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, Spacing.xl)
                    .listRowBackground(Color.clear)
            } else if repos.isEmpty {
                Text(t("github.repos.empty")).foregroundStyle(.secondary)
            } else {
                ForEach(repos) { repo in
                    Button { actionRepo = repo } label: { GitHubRepoRow(repo: repo) }
                        .tint(.primary)
                }
            }
        }
        .navigationTitle(owner.login)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query)
        .onChange(of: query) { _, _ in Task { await load() } }
        .task { await load() }
        .sheet(item: $actionRepo, onDismiss: {
            if let r = pendingCreate { pendingCreate = nil; projectRepo = r }
        }) { repo in
            RepoActionsSheet(
                repo: repo,
                onCreateProject: { pendingCreate = repo },
                onOpen: { if let url = URL(string: "https://github.com/\(repo.fullName)") { openURL(url) } }
            )
        }
        .sheet(item: $projectRepo) { repo in
            NewProjectScreen(presetRepo: repo, presetAccount: account) {
                projectRepo = nil
                dismiss()
            }
        }
    }

    private func load() async {
        loading = true
        let svc = BackendFactory.githubService(for: account, stores: stores)
        repos = (try? await svc.repos(account: account, owner: owner, query: query.isEmpty ? nil : query)) ?? []
        loading = false
    }
}

/// Bottom action sheet for a tapped repo — swipe-up (medium detent) quick actions.
private struct RepoActionsSheet: View {
    let repo: GitHubRepo
    var onCreateProject: () -> Void
    var onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let d = repo.description, !d.isEmpty {
                    Section { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                }
                Section {
                    Button { onCreateProject(); dismiss() } label: {
                        Label(t("github.repo.createProject"), icon: .folderPlus)
                    }
                    .tint(.primary)
                    Button { onOpen(); dismiss() } label: {
                        Label(t("github.repo.open"), icon: .arrowUpRight)
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle(repo.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
