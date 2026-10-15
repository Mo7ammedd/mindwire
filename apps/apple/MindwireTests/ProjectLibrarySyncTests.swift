import XCTest
@testable import Mindwire

@MainActor
final class ProjectLibrarySyncTests: XCTestCase {
    private let workspace = Workspace(id: "mac", name: "Mac", runtime: .server(serverId: "library-test"), createdAt: "2026-10-01T00:00:00Z")
    private let work = ProjectFolder(id: "work", name: "Work")
    private let personal = ProjectFolder(id: "personal", name: "Personal")

    private func project(_ id: String, workspace: String = "mac", sync: String? = nil) -> Project {
        Project(id: id, name: id, workspaceId: workspace, path: "/projects/\(id)", createdAt: "2026-10-01T00:00:00Z", revision: 1, syncId: sync)
    }

    private func stores(_ projects: [Project]) throws -> Stores {
        let suite = "project-library-sync-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        projects.forEach(stores.projects.save)
        stores.projectLibrary.syncRequested = nil
        return stores
    }

    private func snapshot(_ library: DaemonProjectLibrary, projects: [Project]) -> WorkspaceMetadata {
        .init(version: 1, workspaceId: "database", revision: max(1, library.revision), full: true,
              agents: [], projects: projects, chats: [], deleted: [], projectLibrary: library)
    }

    private func repository(_ stores: Stores, _ remote: WorkspaceRemoteFixture) -> WorkspaceDataRepository {
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
            resolveWorkspace: { [workspace] id in id == workspace.id ? workspace : nil })
        stores.workspaceData = data
        return data
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            if ContinuousClock.now >= deadline { XCTFail("Library sync did not settle"); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testFreshSnapshotIsReadOnlyAndRestoresAnotherPhonesFoldersAndOrder() throws {
        let p = project("P"), q = project("Q")
        let stores = try stores([p, q]), library = stores.projectLibrary
        let remote = DaemonProjectLibrary(revision: 4, folders: [work, personal], membership: [p.id: work.id], order: [q.id, p.id])
        XCTAssertTrue(library.receive(remote, workspaceId: workspace.id, identity: "database"))
        XCTAssertEqual(library.folderId(for: p), work.id)
        XCTAssertEqual(library.sorted([p, q]).map(\.id), [q.id, p.id])
        XCTAssertEqual(library.sort, .custom)
        XCTAssertNil(library.nextEdit(workspaceId: workspace.id))
        let saved = stores.defaults.data(forKey: ProjectLibrary.storageKey)
        for _ in 0..<5 {
            library.reconcile(projects: [p, q])
            library.receive(remote, workspaceId: workspace.id, identity: "database")
        }
        XCTAssertEqual(stores.defaults.data(forKey: ProjectLibrary.storageKey), saved)
        XCTAssertTrue(library.pendingWorkspaces.isEmpty, "Reads and navigation must not echo edits")
    }

    func testLayoutPreferenceStaysLocalAndSurvivesWorkspaceRefresh() throws {
        let p = project("P"), stores = try stores([project("P")])
        let library = stores.projectLibrary
        library.receive(.init(revision: 1, folders: [work]), workspaceId: workspace.id, identity: "database")
        library.setLayout(.grid)
        library.setView(.folders)
        XCTAssertNil(library.nextEdit(workspaceId: workspace.id), "Changing the display must not queue a daemon write")
        library.receive(.init(revision: 2, folders: [work], membership: [p.id: work.id]),
                        workspaceId: workspace.id, identity: "database")
        let restored = Stores(defaults: stores.defaults).projectLibrary
        XCTAssertEqual(restored.layout, .grid)
        XCTAssertEqual(restored.view, .folders)
        XCTAssertEqual(restored.folderId(for: p), work.id)
        XCTAssertNil(restored.nextEdit(workspaceId: workspace.id))
    }

    func testLegacyOrganizationImportsOnceAndAcknowledgementPersists() async throws {
        let p = project("P"), q = project("Q")
        let stores = try stores([p, q]), library = stores.projectLibrary
        let folder = try XCTUnwrap(library.createFolder(name: "Client Work"))
        library.move([p], to: folder.id)
        library.reorderProjects([q, p], allProjects: [p, q])
        let remote = WorkspaceRemoteFixture(), data = repository(stores, remote)
        remote.current = snapshot(.init(), projects: [p, q])
        try data.apply(remote.current, workspaceId: workspace.id)
        var writes = 0
        let saved = DaemonProjectLibrary(revision: 2, folders: [folder], membership: [p.id: folder.id], order: [q.id, p.id])
        remote.editLibrary = { edit in
            writes += 1
            XCTAssertTrue(edit.importIfEmpty)
            XCTAssertEqual(edit.expectedRevision, 0)
            XCTAssertEqual(edit.placements, [.init(projectId: p.id, folderId: folder.id)])
            XCTAssertEqual(edit.order, [q.id, p.id])
            return saved
        }
        await data.waitForProjectLibrarySync(workspaceId: workspace.id)
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(library.pendingWorkspaces.isEmpty)
        let reopened = Stores(defaults: stores.defaults)
        reopened.projectLibrary.syncRequested = nil
        XCTAssertEqual(reopened.projectLibrary.folderId(for: p), folder.id)
        XCTAssertNil(reopened.projectLibrary.nextEdit(workspaceId: workspace.id))
        XCTAssertEqual(remote.prepareAllowInstall, [false])
    }

    func testServiceUpgradeDiscoversEmptyLibraryDespiteUnchangedRegistryCursor() async throws {
        let p = project("P"), stores = try stores([project("P")])
        let remote = WorkspaceRemoteFixture(), data = repository(stores, remote), library = stores.projectLibrary
        let folder = try XCTUnwrap(library.createFolder(name: "Work"))
        library.move([p], to: folder.id)
        remote.current = .init(version: 1, workspaceId: "database", revision: 4, full: true,
                               agents: [], projects: [p], chats: [], deleted: [])
        await data.refresh(workspace)
        XCTAssertFalse(library.isSaved(workspaceId: "mac"))
        XCTAssertNotNil(library.syncErrors["mac"])
        remote.supportsProjectLibrary = true
        remote.current = .init(version: 1, workspaceId: "database", revision: 4, full: false,
                               agents: [], projects: [], chats: [], deleted: [])
        var reads = 0, writes = 0
        remote.readLibrary = { reads += 1; return .init() }
        remote.editLibrary = { edit in
            writes += 1
            XCTAssertTrue(edit.importIfEmpty)
            return .init(revision: 5, folders: [folder], membership: [p.id: folder.id])
        }
        await data.refresh(workspace)
        await data.waitForProjectLibrarySync(workspaceId: "mac")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(library.isSaved(workspaceId: "mac"))
        XCTAssertNil(library.syncErrors["mac"])
        await data.refresh(workspace)
        XCTAssertEqual(reads, 1, "Capability discovery must not become polling")
    }

    func testMigrationLosingFirstEditRaceHonorsExistingDaemonOrganization() throws {
        let p = project("P"), stores = try stores([project("P")])
        let library = stores.projectLibrary
        let local = try XCTUnwrap(library.createFolder(name: "Local"))
        library.move([p], to: local.id)
        library.receive(.init(), workspaceId: workspace.id, identity: "database")
        let queued = try XCTUnwrap(library.nextEdit(workspaceId: workspace.id))
        // Another phone edited first; importIfEmpty returns that existing state unchanged.
        library.receive(.init(revision: 2, folders: [work]), workspaceId: workspace.id,
                        identity: "database", acknowledging: queued.id)
        XCTAssertNil(library.folderId(for: p))
        XCTAssertEqual(library.folders, [work])
        XCTAssertNil(library.nextEdit(workspaceId: workspace.id))
    }

    func testOfflineEditsSurviveRelaunchWithoutDuplicatingPlacements() throws {
        let p = project("P"), stores = try stores([project("P")])
        let library = stores.projectLibrary
        library.receive(.init(revision: 1), workspaceId: workspace.id, identity: "database")
        let folder = try XCTUnwrap(library.createFolder(name: "Work"))
        library.move([p], to: folder.id)
        let first = try XCTUnwrap(library.nextEdit(workspaceId: workspace.id))
        var current = library
        for _ in 0..<3 {
            current = Stores(defaults: stores.defaults).projectLibrary
            current.syncRequested = nil
            XCTAssertEqual(current.nextEdit(workspaceId: workspace.id)?.id, first.id)
        }
        current.receive(.init(revision: 2, folders: [folder]), workspaceId: workspace.id, identity: "database", acknowledging: first.id)
        let placement = try XCTUnwrap(current.nextEdit(workspaceId: workspace.id))
        XCTAssertEqual(placement.edit.placements, [.init(projectId: p.id, folderId: folder.id)])
        current.receive(.init(revision: 3, folders: [folder], membership: [p.id: folder.id]),
                        workspaceId: workspace.id, identity: "database", acknowledging: placement.id)
        XCTAssertNil(current.nextEdit(workspaceId: workspace.id), "Relaunch must not append duplicate placement requests")
    }

    func testScopedFolderOrderNeverSendsAnotherWorkspacesUnknownFolder() throws {
        let stores = try stores([project("P"), project("Q", workspace: "cloud")]), library = stores.projectLibrary
        library.receive(.init(revision: 1, folders: [work]), workspaceId: "mac", identity: "mac-db")
        library.receive(.init(revision: 1, folders: [personal]), workspaceId: "cloud", identity: "cloud-db")
        library.reorderFolders([personal.id, work.id])
        XCTAssertEqual(library.nextEdit(workspaceId: "mac")?.edit.folderOrder, [work.id])
        XCTAssertEqual(library.nextEdit(workspaceId: "cloud")?.edit.folderOrder, [personal.id])
        XCTAssertTrue(library.nextEdit(workspaceId: "mac")?.edit.folders.isEmpty == true)
        XCTAssertTrue(library.nextEdit(workspaceId: "cloud")?.edit.folders.isEmpty == true)
    }

    func testReorderingOneFolderDoesNotReplayOtherFoldersProjectOrder() throws {
        let projects = [project("A"), project("B"), project("C"), project("D")]
        let stores = try stores(projects), library = stores.projectLibrary
        library.receive(.init(revision: 1, folders: [work, personal], membership: ["A": work.id, "C": work.id],
                              order: ["A", "B", "C", "D"]), workspaceId: "mac", identity: "database")
        library.reorderProjects([projects[2], projects[0]], allProjects: projects)
        XCTAssertEqual(library.nextEdit(workspaceId: "mac")?.edit.order, ["C", "A"])
        // Another device rearranged the other folder. Rebase must not replay B,D's old order.
        library.receive(.init(revision: 2, folders: [work, personal], membership: ["A": work.id, "C": work.id],
                              order: ["A", "D", "C", "B"]), workspaceId: "mac", identity: "database")
        let queued = try XCTUnwrap(library.nextEdit(workspaceId: "mac"))
        XCTAssertEqual(queued.edit.order, ["C", "A"])
        library.receive(.init(revision: 3, folders: [work, personal], membership: ["A": work.id, "C": work.id],
                              order: ["C", "D", "A", "B"]), workspaceId: "mac", identity: "database", acknowledging: queued.id)
        XCTAssertEqual(library.sorted(projects).map(\.id), ["C", "D", "A", "B"])
    }

    func testRemoteDeletionDropsOnlyDependentOfflineEditsAndKeepsProjects() throws {
        let p = project("P"), q = project("Q"), stores = try stores([project("P"), project("Q")])
        let library = stores.projectLibrary
        library.receive(.init(revision: 1, folders: [work, personal], membership: [p.id: work.id]), workspaceId: "mac", identity: "database")
        library.renameFolder(work.id, name: "Renamed offline")
        library.move([q], to: personal.id)
        library.receive(.init(revision: 2, folders: [personal]), workspaceId: "mac", identity: "database")
        XCTAssertNil(library.folder(work.id))
        XCTAssertNil(library.folderId(for: p))
        XCTAssertEqual(stores.projects.list().count, 2)
        let next = try XCTUnwrap(library.nextEdit(workspaceId: "mac"))
        XCTAssertEqual(next.edit.placements, [.init(projectId: q.id, folderId: personal.id)])
        XCTAssertTrue(next.edit.folders.isEmpty)
        XCTAssertNotNil(library.syncErrors["mac"])
    }

    func testConflictRebasesOnlyLocalIntentAndKeepsOtherDevicesChanges() async throws {
        let p = project("P"), q = project("Q"), stores = try stores([project("P"), project("Q")])
        let remote = WorkspaceRemoteFixture(), data = repository(stores, remote), library = stores.projectLibrary
        try data.apply(snapshot(.init(revision: 1, folders: [work]), projects: [p, q]), workspaceId: "mac")
        library.move([p], to: work.id)
        let other = DaemonProjectLibrary(revision: 2, folders: [work, personal], membership: [q.id: personal.id])
        var calls: [ProjectLibraryEdit] = []
        remote.readLibrary = { other }
        remote.editLibrary = { edit in
            calls.append(edit)
            if calls.count == 1 { throw DaemonHTTPError(status: 409, message: "Changed elsewhere") }
            XCTAssertEqual(edit.expectedRevision, 2)
            XCTAssertEqual(edit.placements, [.init(projectId: p.id, folderId: self.work.id)])
            return .init(revision: 3, folders: other.folders, membership: [p.id: self.work.id, q.id: self.personal.id])
        }
        await data.waitForProjectLibrarySync(workspaceId: "mac")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(library.folderId(for: p), work.id)
        XCTAssertEqual(library.folderId(for: q), personal.id)
        XCTAssertTrue(library.pendingWorkspaces.isEmpty)
        XCTAssertNil(library.syncErrors["mac"])
    }

    func testRejectedEditDoesNotBlockLaterEditsOrPretendItWasSaved() async throws {
        for status in [400, 410] {
            let p = project("P"), q = project("Q"), stores = try stores([project("P"), project("Q")])
            let remote = WorkspaceRemoteFixture(), data = repository(stores, remote), library = stores.projectLibrary
            let initial = DaemonProjectLibrary(revision: 1, folders: [work])
            try data.apply(snapshot(initial, projects: [p, q]), workspaceId: "mac")
            library.renameFolder(work.id, name: "Invalidated")
            library.reorderProjects([q, p], allProjects: [p, q])
            remote.readLibrary = { initial }
            var writes = 0
            remote.editLibrary = { edit in
                writes += 1
                if writes == 1 { throw DaemonHTTPError(status: status, message: "Folder changed on another device") }
                XCTAssertEqual(edit.order, [q.id, p.id])
                return .init(revision: 2, folders: [self.work], order: [q.id, p.id])
            }
            await data.waitForProjectLibrarySync(workspaceId: "mac")
            XCTAssertEqual(writes, 2)
            XCTAssertEqual(library.folder(work.id), work)
            XCTAssertEqual(library.sorted([p, q]).map(\.id), [q.id, p.id])
            XCTAssertTrue(library.pendingWorkspaces.isEmpty)
            XCTAssertNotNil(library.syncErrors["mac"], "Rejected changes need a visible explanation")
        }
    }

    func testUnknownProtocolDoesNotAcknowledgeOrLoopPendingEdit() async throws {
        let p = project("P"), stores = try stores([project("P")])
        let remote = WorkspaceRemoteFixture(), data = repository(stores, remote), library = stores.projectLibrary
        try data.apply(snapshot(.init(revision: 1), projects: [p]), workspaceId: "mac")
        _ = library.createFolder(name: "Work")
        let queued = try XCTUnwrap(library.nextEdit(workspaceId: "mac"))
        var writes = 0
        remote.editLibrary = { _ in writes += 1; return .init(version: 99, revision: 2) }
        await data.waitForProjectLibrarySync(workspaceId: "mac")
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(library.nextEdit(workspaceId: "mac")?.id, queued.id)
        XCTAssertNotNil(library.syncErrors["mac"])
    }

    func testRapidEditsAndRepeatedSyncRequestsShareOneWriter() async throws {
        let p = project("P"), stores = try stores([project("P")])
        let remote = WorkspaceRemoteFixture(), data = repository(stores, remote), library = stores.projectLibrary
        try data.apply(snapshot(.init(revision: 1), projects: [p]), workspaceId: "mac")
        let folder = try XCTUnwrap(library.createFolder(name: "Work"))
        var gate: CheckedContinuation<DaemonProjectLibrary, Error>?
        var edits: [ProjectLibraryEdit] = []
        remote.editLibrary = { edit in
            edits.append(edit)
            if edits.count == 1 { return try await withCheckedThrowingContinuation { gate = $0 } }
            return .init(revision: Int64(edits.count + 1),
                         folders: [.init(id: folder.id, name: edits.count == 3 ? "Clients" : "Work")], membership: [p.id: folder.id])
        }
        data.syncProjectLibraries()
        data.syncProjectLibraries()
        try await eventually { gate != nil }
        library.move([p], to: folder.id)
        library.renameFolder(folder.id, name: "Clients")
        data.syncProjectLibraries()
        XCTAssertEqual(edits.count, 1, "An edit arriving during an upload must join its existing writer")
        gate?.resume(returning: .init(revision: 2, folders: [folder]))
        await data.waitForProjectLibrarySync(workspaceId: "mac")
        XCTAssertEqual(edits.map(\.expectedRevision), [1, 2, 3])
        XCTAssertEqual(library.folder(folder.id)?.name, "Clients")
        XCTAssertEqual(library.folderId(for: p), folder.id)
        XCTAssertTrue(library.pendingWorkspaces.isEmpty)
    }

    func testLateReplyAfterForgettingWorkspaceCannotClearItsNewSyncJob() async throws {
        let p = project("P"), stores = try stores([project("P")])
        let remote = WorkspaceRemoteFixture(), data = repository(stores, remote), library = stores.projectLibrary
        let initial = snapshot(.init(revision: 1, folders: [work]), projects: [p])
        try data.apply(initial, workspaceId: "mac")
        var gates: [CheckedContinuation<DaemonProjectLibrary, Error>] = []
        remote.editLibrary = { _ in try await withCheckedThrowingContinuation { gates.append($0) } }
        library.renameFolder(work.id, name: "Old request")
        data.syncProjectLibraries()
        try await eventually { gates.count == 1 }
        data.forget("mac")
        remote.current = initial
        await data.refresh(workspace)
        library.renameFolder(work.id, name: "New request")
        data.syncProjectLibraries()
        try await eventually { gates.count == 2 }
        gates[0].resume(returning: .init(revision: 2, folders: [.init(id: work.id, name: "Old request")]))
        // Let the cancelled writer's deferred cleanup execute while the new request is held.
        try await Task.sleep(for: .milliseconds(30))
        data.syncProjectLibraries()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(gates.count, 2)
        for gate in gates.dropFirst() { gate.resume(returning: .init(revision: 2, folders: [.init(id: work.id, name: "New request")])) }
        await data.waitForProjectLibrarySync(workspaceId: "mac")
        XCTAssertEqual(library.folder(work.id)?.name, "New request")
        XCTAssertTrue(library.pendingWorkspaces.isEmpty)
    }

    func testFullSnapshotCanRestoreOlderDatabaseWithoutRepeatedWrites() throws {
        let p = project("P"), stores = try stores([project("P")])
        let remote = WorkspaceRemoteFixture(), data = repository(stores, remote)
        try data.apply(snapshot(.init(revision: 8, folders: [work], membership: [p.id: work.id]), projects: [p]), workspaceId: "mac")
        try data.apply(snapshot(.init(revision: 3, folders: [personal], membership: [p.id: personal.id]), projects: [p]), workspaceId: "mac")
        XCTAssertEqual(stores.projectLibrary.folderId(for: p), personal.id)
        XCTAssertTrue(stores.projectLibrary.pendingWorkspaces.isEmpty)
        XCTAssertEqual(data.identity(workspaceId: "mac"), "database")
    }

    func testNewWorkspaceCopyKeepsLogicalFolderWithoutChangingSource() throws {
        let source = project("source", sync: "logical"), destination = project("copy", workspace: "cloud", sync: "logical")
        let stores = try stores([source]), library = stores.projectLibrary
        library.receive(.init(revision: 1, folders: [work], membership: [source.id: work.id]), workspaceId: "mac", identity: "mac-db")
        library.receive(.init(revision: 1), workspaceId: "cloud", identity: "cloud-db")
        library.reconcile(projects: [source, destination])
        XCTAssertNil(library.nextEdit(workspaceId: "mac"))
        let queued = try XCTUnwrap(library.nextEdit(workspaceId: "cloud"))
        XCTAssertEqual(queued.edit.placements, [.init(projectId: destination.id, folderId: work.id)])
        XCTAssertEqual(queued.edit.folders, [work])
        XCTAssertEqual(library.folderId(for: destination), work.id)
    }
}
