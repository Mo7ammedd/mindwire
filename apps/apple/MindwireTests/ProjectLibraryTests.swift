import XCTest
@testable import Mindwire

@MainActor
final class ProjectLibraryTests: XCTestCase {
    private func stores() throws -> Stores {
        let suite = "project-library-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func project(_ id: String, date: Int = 1, workspace: String = "mac", sync: String? = nil) -> Project {
        Project(id: id, name: id, workspaceId: workspace, path: "/projects/\(id)",
                createdAt: "2026-10-01T09:00:0\(date)Z", syncId: sync)
    }

    func testExistingProjectsKeepRecentOrderWithoutWritingOnReadOrIdleReconciliation() throws {
        let stores = try stores(), library = stores.projectLibrary
        let projects = [project("Old", date: 1), project("New", date: 3), project("Middle", date: 2)]
        XCTAssertEqual(library.view, .all)
        XCTAssertEqual(library.layout, .list)
        XCTAssertEqual(library.sort, .recent)
        for _ in 0..<5 {
            XCTAssertEqual(library.sorted(projects).map(\.id), ["New", "Middle", "Old"])
            library.reconcile(projects: projects)
        }
        XCTAssertNil(stores.defaults.data(forKey: ProjectLibrary.storageKey), "A cold library does not write on every refresh")
    }

    func testManualOrderAndViewPersistAndDoNotChangeWhenAProjectIsOpened() throws {
        let stores = try stores()
        let a = project("Alpha", date: 3), b = project("Beta", date: 2), c = project("Gamma")
        [a, b, c].forEach(stores.projects.save)
        stores.projectLibrary.reorderProjects([c, a, b], allProjects: [a, b, c])
        stores.projectLibrary.setView(.folders)
        stores.projectLibrary.setLayout(.grid)
        stores.touchProject(b.id)
        let reopened = Stores(defaults: stores.defaults)
        XCTAssertEqual(reopened.projectLibrary.sort, .custom)
        XCTAssertEqual(reopened.projectLibrary.view, .folders)
        XCTAssertEqual(reopened.projectLibrary.layout, .grid)
        XCTAssertEqual(reopened.projectLibrary.sorted(reopened.projectsByRecency()).map(\.id), [c.id, a.id, b.id])
        reopened.projectLibrary.setSort(.name)
        XCTAssertEqual(reopened.projectLibrary.sorted([c, a, b]).map(\.id), [a.id, b.id, c.id])
        reopened.projectLibrary.setSort(.custom)
        XCTAssertEqual(reopened.projectLibrary.sorted([a, b, c]).map(\.id), [c.id, a.id, b.id])
    }

    func testReorderWithinFolderPreservesOtherSlotsAndUnavailableProjects() throws {
        let library = try stores().projectLibrary
        let a = project("A", date: 4), b = project("B", date: 3), c = project("C", date: 2), d = project("D")
        let all = [a, b, c, d]
        let folder = try XCTUnwrap(library.createFolder(name: "Work"))
        library.move([a, c], to: folder.id)
        library.reorderProjects(all, allProjects: all)
        library.reorderProjects([c, a], allProjects: all)
        XCTAssertEqual(library.sorted(all).map(\.id), [c.id, b.id, a.id, d.id])
        library.reconcile(projects: [a, c, d])
        library.reorderProjects([a, c], allProjects: [a, c, d])
        XCTAssertEqual(library.sorted(all).map(\.id), [a.id, b.id, c.id, d.id])
        XCTAssertEqual(library.folderId(for: c), folder.id)
    }

    func testFoldersValidateNamesRenameAndReorderWithoutDuplicateGroups() throws {
        let stores = try stores(), library = stores.projectLibrary
        let first = try XCTUnwrap(library.createFolder(name: "  Client Work \n"))
        let second = try XCTUnwrap(library.createFolder(name: "Personal"))
        XCTAssertEqual(first.name, "Client Work")
        XCTAssertNil(library.createFolder(name: "client work"))
        XCTAssertNil(library.createFolder(name: " \n"))
        XCTAssertNil(library.createFolder(name: String(repeating: "x", count: 81)))
        library.renameFolder(first.id, name: second.name)
        XCTAssertEqual(library.folder(first.id)?.name, first.name)
        library.renameFolder(first.id, name: "Clients")
        library.reorderFolders([second.id, first.id])
        let reopened = Stores(defaults: stores.defaults).projectLibrary
        XCTAssertEqual(reopened.folders.map(\.name), ["Personal", "Clients"])
        XCTAssertEqual(reopened.folders.map(\.id), [second.id, first.id])
    }

    func testFolderPickerKeepsOtherGroupsAndScopedEditsKeepHiddenMembers() throws {
        let library = try stores().projectLibrary
        let folder = try XCTUnwrap(library.createFolder(name: "Work"))
        let other = try XCTUnwrap(library.createFolder(name: "Personal"))
        let a = project("A"), b = project("B"), remote = project("Remote", workspace: "cloud")
        library.move([a, remote], to: folder.id)
        library.move([b], to: other.id)
        library.setMembers([library.key(for: b)], in: folder.id, candidates: [a, b])
        XCTAssertNil(library.folderId(for: a))
        XCTAssertEqual(library.folderId(for: b), other.id, "A membership picker cannot claim another folder's project")
        XCTAssertEqual(library.folderId(for: remote), folder.id, "Editing one workspace must not remove another workspace's project")
        library.move([b], to: folder.id)
        XCTAssertEqual(library.folderId(for: b), folder.id, "Move to Folder explicitly changes the one membership")
        library.move([b], to: nil)
        XCTAssertNil(library.folderId(for: b))
        XCTAssertFalse(library.move([remote], to: "deleted-folder"))
        XCTAssertEqual(library.folderId(for: remote), folder.id)
    }

    func testNewFolderOnlyOffersUnassignedProjectsAndEditingIncludesItsOwnMembers() throws {
        let library = try stores().projectLibrary
        let work = try XCTUnwrap(library.createFolder(name: "Work"))
        let personal = try XCTUnwrap(library.createFolder(name: "Personal"))
        let a = project("A"), b = project("B"), c = project("C")
        library.move([a], to: work.id)
        XCTAssertEqual(library.eligibleMembers([a, b, c], in: personal.id).map(\.id), [b.id, c.id])
        XCTAssertEqual(library.eligibleMembers([a, b, c], in: work.id).map(\.id), [a.id, b.id, c.id])

        // The picker opened before B was assigned on another device/window.
        let draft = library.eligibleMembers([a, b, c], in: personal.id)
        library.move([b], to: work.id)
        library.setMembers(Set(draft.map { library.key(for: $0) }), in: personal.id, candidates: draft)
        XCTAssertEqual(library.folderId(for: a), work.id)
        XCTAssertEqual(library.folderId(for: b), work.id)
        XCTAssertEqual(library.folderId(for: c), personal.id)
        XCTAssertEqual(library.eligibleMembers([a, b, c], in: personal.id).map(\.id), [c.id])
    }

    func testOrganizationSurvivesRegistryRefreshAndSwitchingWorkspaceCopies() throws {
        let stores = try stores(), library = stores.projectLibrary
        let source = project("Source", date: 1), neighbor = project("Neighbor", date: 2)
        [source, neighbor].forEach(stores.projects.save)
        let folder = try XCTUnwrap(library.createFolder(name: "Client Work"))
        library.move([source], to: folder.id)
        library.reorderProjects([source, neighbor], allProjects: [source, neighbor])

        var synced = source; synced.syncId = "shared-project"; synced.name = "Updated on Mac"
        try stores.workspaceData.apply(.init(version: 1, workspaceId: "mac-registry", revision: 1,
            full: true, agents: [], projects: [synced, neighbor], chats: [], deleted: []), workspaceId: "mac")
        let replica = project("Replica", date: 4, workspace: "cloud", sync: "shared-project")
        try stores.workspaceData.apply(.init(version: 1, workspaceId: "cloud-registry", revision: 1,
            full: true, agents: [], projects: [replica], chats: [], deleted: []), workspaceId: "cloud")
        stores.touchProject(replica.id)
        XCTAssertEqual(library.sorted(stores.projectsByRecency()).map(\.id), [replica.id, neighbor.id])
        XCTAssertEqual(library.folderId(for: replica), folder.id)
        stores.touchProject(source.id)
        let current = try XCTUnwrap(stores.projects.get(source.id))
        XCTAssertEqual(library.folderId(for: current), folder.id)
        XCTAssertEqual(library.sorted(stores.projectsByRecency()).map(\.id), [source.id, neighbor.id])
        XCTAssertEqual(stores.projects.list().count, 3, "Every workspace's project remains intact")
    }

    func testCreationInsideFolderResolvesDaemonCanonicalIDAfterRelaunch() throws {
        let stores = try stores(), library = stores.projectLibrary
        let folder = try XCTUnwrap(library.createFolder(name: "New Work"))
        let operation = ProjectOperation(id: "request", source: "clone", name: "App", path: "/projects/app",
            status: "running", phase: "cloning", createdAt: "2026-10-01T09:00:00Z",
            updatedAt: "2026-10-01T09:00:00Z", sequence: 1, attempt: 1)
        library.placeCreation(operation, workspaceId: "cloud", in: folder.id, projects: [])
        let entry = ProjectListEntry(workspaceId: "cloud", projectId: "request", operation: operation)
        XCTAssertEqual(library.folderId(for: entry), folder.id)
        let reopened = Stores(defaults: stores.defaults)
        var project = project("canonical-id", workspace: "cloud"); project.path = operation.path
        try reopened.workspaceData.apply(.init(version: 1, workspaceId: "cloud-registry", revision: 1,
            full: true, agents: [], projects: [project], chats: [], deleted: []), workspaceId: "cloud")
        XCTAssertEqual(reopened.projectLibrary.folderId(for: project), folder.id)
        XCTAssertNil(reopened.projectLibrary.folderId(for: entry), "Pending placement is consumed after registry reconciliation")
    }

    func testDeletingFolderKeepsProjectDataChatsFilesAndOrder() throws {
        let stores = try stores(), library = stores.projectLibrary
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.swift")
        try Data("let original = true\n".utf8).write(to: file)
        var a = project("A"); a.path = directory.path
        let b = project("B", date: 2)
        [a, b].forEach(stores.projects.save)
        let chat = Chat(id: "chat", agentId: "agent", projectId: a.id, title: "Keep this", createdAt: a.createdAt)
        stores.chats.save(chat)
        let folder = try XCTUnwrap(library.createFolder(name: "Work"))
        library.move([a, b], to: folder.id)
        library.reorderProjects([a, b], allProjects: [a, b])
        library.deleteFolder(folder.id)
        XCTAssertNil(library.folderId(for: a))
        XCTAssertTrue(library.folders.isEmpty)
        XCTAssertEqual(stores.projects.get(a.id), a)
        XCTAssertEqual(stores.chats.get(chat.id)?.title, chat.title)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let original = true\n")
        XCTAssertEqual(library.sorted(stores.projectsByRecency()).map(\.id), [a.id, b.id])
    }
}
