import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class ProjectPresentationTests: XCTestCase {
    private func stores() throws -> Stores {
        let suite = "project-presentation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func project(_ id: String = "project") -> Project {
        .init(id: id, name: "Mindwire", workspaceId: "workspace", path: "/home/user/development/mindwire", createdAt: "2026-09-26T00:00:00Z", revision: 1)
    }

    private func status(branch: String = "main", changed: Bool = true) -> GitStatus {
        .init(isRepo: true, root: project().path, branch: branch, ahead: 0, behind: 0, detached: false,
              files: changed ? [
                .init(path: "App.swift", kind: "modified", index: "M", worktree: "M",
                      staged: .init(additions: 12, deletions: 3), unstaged: .init(additions: 4, deletions: 1)),
                .init(path: "image.png", kind: "untracked", index: "?", worktree: "?")
              ] : [])
    }

    private func icon() -> ProjectIconData {
        .init(path: "assets/icon.svg", mediaType: "image/svg+xml",
              content: Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><path fill="#a9dc76" d="M24 1L45 13v22L24 47 3 35V13z"/><path fill="#282a3a" d="M14 16h6l4 8 4-8h6v18h-6v-8l-4 8-4-8v8h-6z"/></svg>"##.utf8), etag: "fixture")
    }

    func testGitSnapshotsPersistWithoutNavigationReadsAndManualRefreshReplacesThem() async throws {
        let stores = try stores(), project = project()
        let cache = stores.projectPresentation
        cache.reconcile(projects: [project], workspaceId: project.workspaceId, registryId: "registry")
        var reads = 0
        let read: @MainActor (Project) async throws -> GitStatus? = { _ in reads += 1; return self.status() }
        let noIcon: @MainActor (Project) async throws -> ProjectIconData = { _ in throw URLError(.unsupportedURL) }
        await cache.refresh(projects: [project], registryId: "registry", status: read, icon: noIcon)
        let summary = try XCTUnwrap(cache.git(for: project))
        XCTAssertEqual(summary.changedFiles, 2, "A file changed in both the index and worktree counts once")
        XCTAssertEqual(summary.additions, 16)
        XCTAssertEqual(summary.deletions, 4)
        for _ in 0..<3 { await cache.refresh(projects: [project], registryId: "registry", status: read, icon: noIcon) }
        XCTAssertEqual(reads, 1)
        let reopened = ProjectPresentationCache(defaults: stores.defaults)
        XCTAssertEqual(reopened.git(for: project), summary)
        await reopened.refresh(projects: [project], registryId: "registry", status: read, icon: noIcon)
        XCTAssertEqual(reads, 1, "Relaunch serves the persisted snapshot without another fresh read")
        await reopened.refresh(projects: [project], registryId: "registry", force: true, status: { _ in
            reads += 1; return self.status(branch: "feature/new", changed: false)
        }, icon: noIcon)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(reopened.git(for: project)?.branch, "feature/new")
        XCTAssertEqual(reopened.git(for: project)?.changedFiles, 0)
    }

    func testConcurrentChecksJoinAndCannotRollBackNewerSourceControlStatus() async throws {
        let cache = try stores().projectPresentation, project = project()
        cache.reconcile(projects: [project], workspaceId: project.workspaceId, registryId: "registry")
        var continuation: CheckedContinuation<GitStatus?, Never>?
        var reads = 0
        let read: @MainActor (Project) async throws -> GitStatus? = { _ in
            reads += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let noIcon: @MainActor (Project) async throws -> ProjectIconData = { _ in throw URLError(.unsupportedURL) }
        let first = Task { await cache.refresh(projects: [project], registryId: "registry", force: true, status: read, icon: noIcon) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let second = Task { await cache.refresh(projects: [project], registryId: "registry", force: true, status: read, icon: noIcon) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reads, 1)
        cache.record(status: status(branch: "renamed", changed: false), for: project)
        let gate = try XCTUnwrap(continuation)
        gate.resume(returning: status())
        await first.value; await second.value
        XCTAssertEqual(cache.git(for: project)?.branch, "renamed")
        XCTAssertEqual(cache.git(for: project)?.changedFiles, 0)
        XCTAssertTrue(cache.loading.isEmpty)
    }

    func testProjectIconRendersAndSurvivesRelaunchButNotRegistryReplacementOrRemoval() throws {
        let stores = try stores()
        var project = project()
        project.iconPath = icon().path
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProjectPresentationCache(defaults: stores.defaults, directory: directory)
        cache.reconcile(projects: [project], workspaceId: project.workspaceId, registryId: "registry")
        try cache.record(icon: icon(), for: project)
        let rendered = try XCTUnwrap(cache.icon(for: project))
        XCTAssertEqual(rendered.size.width * rendered.scale, 256)
        cache.record(status: status(), for: project)
        let reopened = ProjectPresentationCache(defaults: stores.defaults, directory: directory)
        XCTAssertNotNil(reopened.icon(for: project))
        XCTAssertNotNil(reopened.git(for: project))
        reopened.reconcile(projects: [project], workspaceId: project.workspaceId, registryId: "replacement-registry")
        XCTAssertNil(reopened.icon(for: project))
        XCTAssertNil(reopened.git(for: project))
        try reopened.record(icon: icon(), for: project)
        reopened.reconcile(projects: [], workspaceId: project.workspaceId, registryId: "replacement-registry")
        XCTAssertNil(reopened.icon(for: project))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertNil(ProjectIconSheet.relativePath("/home/user/development/mindwire-other/icon.svg", root: project.path))
        XCTAssertNil(ProjectIconSheet.relativePath(project.path + "/../private.svg", root: project.path))
    }

    func testChoosingAndResettingIconRequiresDaemonAcknowledgement() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        let workspace = Workspace(id: "workspace", name: "My computer", runtime: .server(serverId: "fixture"), createdAt: isoNow())
        remote.supportsProjectOperations = true
        remote.supportsProjectIcons = true
        var project = project()
        project.workspaceId = "database"
        remote.current = .init(version: 1, workspaceId: "database", revision: 1, full: true,
                               agents: [], projects: [project], chats: [], deleted: [])
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, resolveWorkspace: { _ in workspace })
        stores.workspaceData = data
        await data.refreshIfNeeded(workspace)
        var writes: [[String: Any]] = []
        remote.onPut = { _, _, payload, revision in
            writes.append(try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any]))
            XCTAssertEqual(revision, remote.current.projects[0].revision)
            var saved = try JSONDecoder().decode(Project.self, from: payload)
            saved.workspaceId = "database"; saved.revision = (revision ?? 0) + 1
            remote.current = .init(version: 1, workspaceId: "database", revision: saved.revision!, full: true,
                                   agents: [], projects: [saved], chats: [], deleted: [])
            return remote.current
        }
        try await data.setProjectIcon(project.id, path: "assets/icon.svg")
        XCTAssertEqual(stores.projects.get(project.id)?.iconPath, "assets/icon.svg")
        try await data.setProjectIcon(project.id, path: nil)
        XCTAssertNil(stores.projects.get(project.id)?.iconPath)
        XCTAssertTrue(writes.last?["iconPath"] is NSNull, "Reset must send explicit null, not omit the field")
        remote.supportsProjectIcons = false
        do { try await data.setProjectIcon(project.id, path: "assets/another.png"); XCTFail("Old daemon must not silently drop the icon") }
        catch { XCTAssertEqual(error.localizedDescription, t("project.icon.updateRequired")) }
        XCTAssertEqual(writes.count, 2)
    }

    func testProjectCardsUseCachedBranchAndDiffWithoutFullPaths() async throws {
        let stores = try stores()
        let workspace = Workspace(id: "workspace", name: "My Mac", runtime: .server(serverId: "fixture"), createdAt: isoNow())
        stores.workspaces.save(workspace)
        let repository = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores)])
        var first = project("cards-svg")
        first.iconPath = icon().path
        var second = project("cards-folder")
        second.name = "Website"
        var third = project("cards-binary")
        third.name = "Design System"
        let projects = [first, second, third]
        let agentId = "card-agent-\(UUID().uuidString)", chatId = "card-chat-\(UUID().uuidString)"
        stores.agents.save(Agent(id: agentId, name: "Codex", agentType: .codex, workspaceId: workspace.id, createdAt: isoNow()))
        stores.chats.save(Chat(id: chatId, agentId: agentId, projectId: first.id, title: "Working on icons", createdAt: isoNow(), sessionId: nil))
        ChatActivityStore.shared.record(.init(id: "run", chatId: chatId, status: .running, createdAt: isoNow()), workspaceId: workspace.id)
        defer { ChatActivityStore.shared.remove(chatId) }
        stores.projectPresentation.reconcile(projects: projects, workspaceId: workspace.id, registryId: "registry")
        try stores.projectPresentation.record(icon: icon(), for: first)
        stores.projectPresentation.record(status: status(branch: "feature/projects"), for: first)
        stores.projectPresentation.record(status: status(branch: "main", changed: false), for: second)
        var binary = status(branch: "design"); binary.files = [binary.files[1]]
        stores.projectPresentation.record(status: binary, for: third)
        let entries = projects.map { ProjectListEntry(workspaceId: workspace.id, projectId: $0.id, project: $0) }
        for scheme in [ColorScheme.dark, .light] {
            let view = NavigationStack {
                List {
                    ProjectListRows(entries: entries, showWorkspace: true, separateSections: true,
                                    repository: repository, selectedOperation: .constant(nil))
                }
                .listSectionSpacing(.compact)
                .navigationTitle(t("tabs.projects"))
            }
            .environment(\.stores, stores).preferredColorScheme(scheme)
            let host = UIHostingController(rootView: view)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(650))
            let image = ChatFeedSnapshot.image(host)
            let name = "mindwire-project-cards-\(scheme)"
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
            let text = try ChatFeedSnapshot.visibleText(in: image)
            XCTAssertTrue(text.contains("Mindwire"), text)
            XCTAssertTrue(text.contains("My Mac"), text)
            XCTAssertTrue(text.contains("feature/projects"), text)
            XCTAssertTrue(text.contains("1 file"), text)
            XCTAssertFalse(text.contains("/home/user"), text)
            window.isHidden = true
        }
    }

    func testIconFormOpensWithTheCachedPreviewAndProjectFilePickerAction() async throws {
        let stores = try stores()
        let workspace = Workspace(id: "workspace", name: "My Mac", runtime: .server(serverId: "fixture"), createdAt: isoNow())
        stores.workspaces.save(workspace)
        let repository = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores)])
        var project = project()
        project.iconPath = icon().path
        stores.projects.save(project)
        stores.projectPresentation.reconcile(projects: [project], workspaceId: workspace.id, registryId: "registry")
        try stores.projectPresentation.record(icon: icon(), for: project)
        let host = UIHostingController(rootView: ProjectIconSheet(projectId: project.id, repository: repository)
            .environment(\.stores, stores).preferredColorScheme(.dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(650))
        let image = ChatFeedSnapshot.image(host)
        let attachment = XCTAttachment(image: image); attachment.name = "project-icon"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-project-icon.png"))
        let text = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(text.contains("icon.svg"), text)
        XCTAssertTrue(text.contains(t("project.icon.chooseFile")), text)
        XCTAssertTrue(text.contains(t("project.icon.reset")), text)
    }
}
