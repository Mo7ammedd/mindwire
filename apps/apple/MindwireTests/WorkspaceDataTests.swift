import XCTest
@testable import Mindwire

@MainActor
final class WorkspaceDataTests: XCTestCase {
    private let workspace = Workspace(id: "connection", name: "Workspace",
        runtime: .server(serverId: "test-connection"), createdAt: "2026-09-16T00:00:00Z")

    private func stores() throws -> Stores {
        let suite = "workspace-data-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func repository(_ stores: Stores, _ remote: WorkspaceRemoteFixture) -> WorkspaceDataRepository {
        WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
                                resolveWorkspace: { [workspace] id in id == workspace.id ? workspace : nil })
    }

    private func populated(revision: Int64 = 1) -> WorkspaceMetadata {
        WorkspaceMetadata(version: 1, workspaceId: "database", revision: revision, full: true,
            agents: [Agent(id: "agent", name: "Codex", agentType: .codex, workspaceId: "database",
                           createdAt: workspace.createdAt, revision: revision)],
            projects: [Project(id: "project", name: "App", workspaceId: "database", path: "/work/app",
                               createdAt: workspace.createdAt, revision: revision)],
            chats: [Chat(id: "chat", agentId: "agent", projectId: "project", title: "Build app",
                         createdAt: workspace.createdAt, sessionId: "native-session", revision: revision)],
            deleted: [])
    }

    private func empty(revision: Int64 = 0, full: Bool = true,
                       deleted: [WorkspaceRecordDeletion] = []) -> WorkspaceMetadata {
        .init(version: 1, workspaceId: "database", revision: revision, full: full,
              agents: [], projects: [], chats: [], deleted: deleted)
    }

    func testSetupUsesCanonicalDaemonProfileAcrossRepeatedAndConcurrentRequests() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = populated()
        remote.current.agents[0].installation = "installed"
        remote.current.agents[0].notificationsMuted = true
        remote.supportsAgentDiscovery = true
        remote.ensure = { type, _ in
            XCTAssertEqual(type, .codex)
            return .init(agentId: "agent", snapshot: remote.current)
        }
        let data = repository(stores, remote)
        async let first = data.createAgent(.init(name: "First phone", agentType: .codex, workspaceId: workspace.id))
        async let second = data.createAgent(.init(name: "Another attempt", agentType: .codex, workspaceId: workspace.id))
        let created = try await [first, second]
        XCTAssertEqual(created.map(\.id), ["agent", "agent"])
        XCTAssertEqual(stores.agents.list().count, 1)
        XCTAssertEqual(stores.agents.get("agent")?.name, "Codex")
        XCTAssertEqual(stores.agents.get("agent")?.notificationsMuted, true)
        XCTAssertEqual(stores.chats.get("chat")?.sessionId, "native-session")
        XCTAssertTrue(remote.putIDs.isEmpty, "Setup must not manufacture a new client-owned profile")
    }

    func testNativeInstallationStateSurvivesRelaunchAndFailuresKeepTheCache() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = populated()
        remote.current.agents[0].installation = "installed"
        let data = repository(stores, remote)
        await data.refresh(workspace)
        let reopened = Stores(defaults: stores.defaults)
        XCTAssertEqual(reopened.agents.get("agent")?.installation, "installed")
        remote.prepareError = URLError(.notConnectedToInternet)
        await data.refresh(workspace)
        XCTAssertEqual(stores.agents.get("agent")?.installation, "installed")
        XCTAssertNotNil(stores.chats.get("chat"))
        var warning = empty(revision: 1, full: false)
        warning.agentDiscoveryIssues = [.init(agent: "codex", message: "Check installation")]
        try data.apply(warning, workspaceId: workspace.id)
        XCTAssertEqual(data.agentDiscoveryIssues[workspace.id]?.count, 1)
        XCTAssertEqual(stores.agents.get("agent")?.installation, "installed")
        remote.prepareError = nil
        remote.current = populated(revision: 2)
        remote.current.agents[0].installation = "missing"
        await data.refresh(workspace)
        XCTAssertEqual(stores.agents.get("agent")?.installation, "missing")
        XCTAssertNotNil(stores.chats.get("chat"), "An uninstall cannot purge native conversation links")
    }

    func testNativeConversationsUseDaemonIdentityAndActivityAcrossRelaunch() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = populated()
        remote.current.chats[0].updatedAt = "2026-09-25T12:00:00Z"
        remote.current.chats.append(Chat(id: "second-native", agentId: "agent", projectId: "project",
            title: "Another CLI conversation", createdAt: "2026-09-24T12:00:00Z", sessionId: "native-two", revision: 1))
        let data = repository(stores, remote)
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(stores.chats(forProjectId: "project").map(\.id), ["chat", "second-native"])
        XCTAssertEqual(stores.chats.get("chat")?.sessionId, "native-session")
        XCTAssertTrue(remote.imports.isEmpty, "Discovering native chats must not manufacture a legacy import")
        let reopened = Stores(defaults: stores.defaults)
        XCTAssertEqual(reopened.chats(forProjectId: "project").map(\.id), ["chat", "second-native"])
        XCTAssertEqual(reopened.chats.get("chat")?.updatedAt, "2026-09-25T12:00:00Z")

        remote.current = populated(revision: 2)
        remote.current.chats[0].title = "Renamed in the native harness"
        remote.current.chats[0].updatedAt = "2026-09-26T12:00:00Z"
        await data.refresh(workspace)
        XCTAssertEqual(stores.chats.list().count, 1)
        XCTAssertEqual(stores.chats.get("chat")?.title, "Renamed in the native harness")
        XCTAssertEqual(stores.chats.get("chat")?.sessionId, "native-session")
    }

    func testManualRefreshBypassesNativeInventoryCacheWithoutNavigationRescans() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = populated()
        let data = repository(stores, remote)
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(remote.sessionRefreshFlags, [false])
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(remote.sessionRefreshFlags, [false])
        await data.refresh(workspace)
        XCTAssertEqual(remote.sessionRefreshFlags, [false, true])
    }

    func testNativeDiscoveryWarningDoesNotEraseChatsOrMarkWorkspaceUnavailable() throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        let data = repository(stores, remote)
        try data.apply(populated(), workspaceId: workspace.id)
        var warning = empty(revision: 1, full: false)
        warning.sessionDiscoveryIssues = [.init(projectId: "project", agent: "codex", message: "Refresh conversations")]
        try data.apply(warning, workspaceId: workspace.id)
        XCTAssertNotNil(stores.chats.get("chat"))
        XCTAssertNil(data.errors[workspace.id])
        XCTAssertEqual(data.sessionDiscoveryIssues[workspace.id]?.count, 1)
        warning.sessionDiscoveryIssues = nil
        try data.apply(warning, workspaceId: workspace.id)
        XCTAssertTrue(data.sessionDiscoveryIssues[workspace.id]?.isEmpty == true)
    }

    func testNotificationMutesRequireAcknowledgementAndPersistForAgentAndChat() async throws {
        for scope in [NotificationScope.agent("agent"), .chat("chat")] {
            let stores = try stores(), remote = WorkspaceRemoteFixture()
            remote.supportsNotificationPreferences = true
            remote.current = populated()
            let data = repository(stores, remote)
            await data.refresh(workspace)
            remote.onPut = { kind, id, payload, expected in
                XCTAssertEqual(expected, remote.current.revision)
                let next = remote.current.revision + 1
                if kind == "agents" {
                    var agent = try JSONDecoder().decode(Agent.self, from: payload)
                    XCTAssertNotEqual(stores.agents.get(id)?.notificationsMuted, agent.notificationsMuted,
                                      "The cache cannot claim the requested value before its acknowledgement")
                    agent.revision = next
                    remote.current.agents = [agent]
                } else {
                    var chat = try JSONDecoder().decode(Chat.self, from: payload)
                    XCTAssertNotEqual(stores.chats.get(id)?.notificationsMuted, chat.notificationsMuted)
                    chat.revision = next
                    remote.current.chats = [chat]
                }
                remote.current = WorkspaceMetadata(version: 1, workspaceId: "database", revision: next, full: true,
                    agents: remote.current.agents, projects: remote.current.projects, chats: remote.current.chats, deleted: [])
                return remote.current
            }
            for muted in [true, false] {
                try await data.setNotificationsMuted(muted, for: scope)
                XCTAssertEqual(scope.savedMute(in: stores), muted)
                XCTAssertEqual(scope.savedMute(in: Stores(defaults: stores.defaults)), muted)
                XCTAssertEqual(remote.prepareAllowInstall.last, false, "Changing a preference must not install software")
            }
        }
    }

    func testOlderDaemonsCannotAcceptLocalOnlyNotificationMutes() async throws {
        for legacy in [false, true] {
            let stores = try stores(), remote = WorkspaceRemoteFixture()
            var cached = populated()
            cached.agents[0].workspaceId = workspace.id
            cached.projects[0].workspaceId = workspace.id
            stores.agents.replaceAll(cached.agents)
            stores.projects.replaceAll(cached.projects)
            stores.chats.replaceAll(cached.chats)
            remote.current = populated()
            if legacy { remote.prepareError = WorkspaceRegistryError.updateRequired }
            let data = repository(stores, remote)
            do {
                try await data.setNotificationsMuted(true, for: .chat("chat"))
                XCTFail("An older daemon cannot promise to enforce a mute")
            } catch WorkspaceRegistryError.notificationPreferencesUnavailable {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertNil(stores.chats.get("chat")?.notificationsMuted)
            XCTAssertTrue(remote.putIDs.isEmpty)
            if !legacy { XCTAssertNil(data.errors[workspace.id]) }
        }
    }

    func testUnconfirmedOrFailedNotificationChangesDoNotBecomeCachedMutes() async throws {
        for disconnected in [false, true] {
            let stores = try stores(), remote = WorkspaceRemoteFixture()
            remote.supportsNotificationPreferences = true
            remote.current = populated()
            let data = repository(stores, remote)
            await data.refresh(workspace)
            remote.onPut = { _, _, _, _ in
                if disconnected { throw URLError(.networkConnectionLost) }
                return remote.current // The server ignored the new field despite claiming support.
            }
            do {
                try await data.setNotificationsMuted(true, for: .chat("chat"))
                XCTFail("A mute needs a matching server acknowledgement")
            } catch {}
            XCTAssertNil(stores.chats.get("chat")?.notificationsMuted)
        }
    }

    func testNotificationConflictReconcilesTheOtherDevicesPreference() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsNotificationPreferences = true
        remote.current = populated()
        let data = repository(stores, remote)
        await data.refresh(workspace)
        remote.onPut = { _, _, _, _ in
            remote.current.chats[0].notificationsMuted = true
            remote.current.chats[0].revision = 2
            remote.current.chats[0].title = "Renamed on another device"
            remote.current = WorkspaceMetadata(version: 1, workspaceId: "database", revision: 2, full: true,
                agents: remote.current.agents, projects: remote.current.projects, chats: remote.current.chats, deleted: [])
            throw DaemonHTTPError(status: 409, message: "record changed")
        }
        do {
            try await data.setNotificationsMuted(false, for: .chat("chat"))
            XCTFail("A stale client must not overwrite the other device")
        } catch let error as DaemonHTTPError { XCTAssertEqual(error.status, 409) }
        XCTAssertEqual(stores.chats.get("chat")?.notificationsMuted, true)
        XCTAssertEqual(stores.chats.get("chat")?.title, "Renamed on another device")
    }

    func testNavigationReusesMetadataAndManualRefreshForcesItsHealthCheck() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        var now = Date()
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, now: { now })
        await data.refreshIfNeeded(workspace)
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(remote.prepareCalls, 1)
        XCTAssertEqual(remote.invalidateCalls, 0)
        XCTAssertTrue(data.syncing.isEmpty)
        await data.refresh(workspace)
        XCTAssertEqual(remote.prepareCalls, 2)
        XCTAssertEqual(remote.invalidateCalls, 1)
        now.addTimeInterval(61)
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(remote.prepareCalls, 3)
    }

    func testMetadataFailureDoesNotStayHealthyOrHammerOnNavigationAndRetryBypassesCooldown() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        var now = Date()
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, now: { now })
        await data.refreshIfNeeded(workspace)
        now.addTimeInterval(61)
        remote.deltaError = URLError(.networkConnectionLost)
        await data.refreshIfNeeded(workspace)
        XCTAssertNotNil(data.errors[workspace.id])
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(remote.prepareCalls, 2)
        remote.deltaError = nil
        await data.refresh(workspace)
        XCTAssertEqual(remote.prepareCalls, 3)
        XCTAssertNil(data.errors[workspace.id])
    }

    func testActiveProjectsKeepPollingAndRuntimeChangesInvalidateHealthyMetadata() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        remote.operations = [ProjectOperation(id: "active-clone", source: "clone", name: "App", path: "/app",
            status: "running", phase: "receiving", createdAt: workspace.createdAt, updatedAt: workspace.createdAt,
            sequence: 1, attempt: 1)]
        var now = Date()
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, now: { now })
        await data.refreshIfNeeded(workspace)
        now.addTimeInterval(5)
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(remote.prepareCalls, 2, "Running jobs cannot wait for the idle cache's expiry")
        data.invalidateChecks(workspace.id)
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(remote.prepareCalls, 3)
    }

    func testManualRefreshDuringAutomaticReadQueuesOneFreshHealthCheck() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.holdSnapshot = true
        let data = repository(stores, remote)
        let background = Task { await data.refreshIfNeeded(workspace) }
        for _ in 0..<100 where remote.snapshotGate == nil { await Task.yield() }
        XCTAssertNotNil(remote.snapshotGate)
        let manual = Task { await data.refresh(workspace) }
        let secondManual = Task { await data.refresh(workspace) }
        await Task.yield()
        remote.releaseSnapshot()
        await background.value
        await manual.value
        await secondManual.value
        XCTAssertEqual(remote.invalidateCalls, 1)
        XCTAssertEqual(remote.prepareCalls, 2)
    }

    func testQuietRevalidationDoesNotShowCheckingAndLateReadCannotRenewAnInvalidatedCache() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        var now = Date()
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, now: { now })
        await data.refreshIfNeeded(workspace)
        now.addTimeInterval(61)
        remote.holdChanges = true
        let background = Task { await data.refreshIfNeeded(workspace) }
        for _ in 0..<100 where remote.changesGate == nil { await Task.yield() }
        XCTAssertNotNil(remote.changesGate)
        XCTAssertFalse(data.syncing.contains(workspace.id))
        data.invalidateChecks(workspace.id)
        remote.releaseChanges()
        await background.value
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(remote.prepareCalls, 3, "A response started before invalidation must not renew freshness")
    }

    func testPowerInvalidationDiscardsAnOlderUnavailableErrorAndManualRefreshChecksAgain() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote })
        await data.refresh(workspace)
        remote.holdChanges = true
        let old = Task { await data.refresh(workspace) }
        for _ in 0..<200 where remote.changesGate == nil { await Task.yield() }
        XCTAssertNotNil(remote.changesGate)
        data.invalidateChecks(workspace.id)
        remote.deltaError = URLError(.cannotConnectToHost)
        remote.releaseChanges()
        await old.value
        XCTAssertNil(data.errors[workspace.id], "A pre-Start response must not restore the old unavailable message")
        remote.deltaError = nil
        let previous = remote.prepareCalls
        await data.refresh(workspace)
        XCTAssertGreaterThan(remote.prepareCalls, previous)
        XCTAssertNil(data.errors[workspace.id])
    }

    func testChangingConnectionReplacesRemoteAndInvalidatesChecksBeforeTheirExpiry() async throws {
        let stores = try stores(), first = WorkspaceRemoteFixture(), second = WorkspaceRemoteFixture()
        second.supportsProjectOperations = true
        var connections = 0
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in
            connections += 1
            return connections == 1 ? first : second
        }, resolveWorkspace: { [workspace] _ in workspace })
        await data.refreshIfNeeded(workspace)
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(connections, 1)
        stores.connections.save(.local(.init(id: "test-connection", name: "Mac", deviceName: "Mac",
                                             pairingId: "fixture", createdAt: workspace.createdAt)))
        try await data.requireProjectSupport(workspaceId: workspace.id)
        XCTAssertEqual(connections, 2)
        XCTAssertEqual(second.prepareCalls, 1)
        XCTAssertEqual(second.snapshotCalls, 1, "A new connection verifies the workspace identity with a full snapshot")
    }

    func testLegacyImportKeepsIDsAndNativeSessionThenFreshCacheRestoresEverything() async throws {
        let first = try stores(), remote = WorkspaceRemoteFixture()
        var legacy = populated()
        legacy.agents[0].workspaceId = workspace.id
        legacy.projects[0].workspaceId = workspace.id
        first.agents.replaceAll(legacy.agents)
        first.projects.replaceAll(legacy.projects)
        first.chats.replaceAll(legacy.chats)
        remote.current = populated()
        let data = repository(first, remote)
        await data.refresh(workspace)
        XCTAssertNil(data.errors[workspace.id])
        XCTAssertEqual(remote.imports.count, 3)
        XCTAssertEqual(remote.imports[0].agents.map(\.id), ["agent"])
        XCTAssertEqual(remote.imports[1].projects.map(\.id), ["project"])
        XCTAssertEqual(remote.imports[2].chats.first?.sessionId, "native-session")
        XCTAssertEqual(first.projects.get("project")?.workspaceId, workspace.id)
        XCTAssertEqual(first.agents.get("agent")?.revision, 1)

        let second = try stores()
        let secondData = repository(second, remote)
        await secondData.refresh(workspace)
        XCTAssertEqual(remote.imports.count, 3, "A fresh cache has nothing to import")
        XCTAssertEqual(second.agents.list(), first.agents.list())
        XCTAssertEqual(second.projects.list(), first.projects.list())
        XCTAssertEqual(second.chats.list(), first.chats.list())
    }

    func testImportFailureKeepsEntireLegacyCacheUntilRetryAcknowledgesIt() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        var legacy = populated()
        legacy.agents[0].workspaceId = workspace.id
        legacy.projects[0].workspaceId = workspace.id
        stores.agents.replaceAll(legacy.agents)
        stores.projects.replaceAll(legacy.projects)
        stores.chats.replaceAll(legacy.chats)
        remote.current = populated()
        remote.failImportCall = 2
        let data = repository(stores, remote)
        await data.refresh(workspace)
        XCTAssertNotNil(data.errors[workspace.id])
        XCTAssertEqual(data.revision, 0)
        XCTAssertEqual(stores.agents.list(), legacy.agents)
        XCTAssertEqual(stores.projects.list(), legacy.projects)
        XCTAssertEqual(stores.chats.list(), legacy.chats)

        remote.failImportCall = nil
        await data.refresh(workspace)
        XCTAssertNil(data.errors[workspace.id])
        XCTAssertEqual(stores.chats.get("chat")?.sessionId, "native-session")
        XCTAssertEqual(data.revision, 1)
    }

    func testRestartRepairsPartialCacheWithoutReimportingDeletedRows() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = populated()
        let data = repository(stores, remote)
        await data.refresh(workspace)
        stores.projects.replaceAll([]) // An interrupted cache write; the durable cursor exists.
        let reopened = repository(stores, remote)
        await reopened.refresh(workspace)
        XCTAssertNotNil(stores.projects.get("project"))
        XCTAssertTrue(remote.imports.isEmpty)
        XCTAssertEqual(remote.snapshotCalls, 2)

        remote.current = empty(revision: 2, deleted: [
            .init(kind: "agents", id: "agent", revision: 2),
            .init(kind: "projects", id: "project", revision: 2),
            .init(kind: "chats", id: "chat", revision: 2)])
        let nextLaunch = repository(stores, remote)
        await nextLaunch.refresh(workspace)
        XCTAssertTrue(stores.agents.list().isEmpty)
        XCTAssertTrue(stores.projects.list().isEmpty)
        XCTAssertTrue(stores.chats.list().isEmpty)
        XCTAssertTrue(remote.imports.isEmpty, "A migrated cache is never sent back as legacy data")
    }

    func testDeltaDeletionPreservesOtherWorkspacesAndUnchangedDeltaDoesNotReloadFeed() throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        let other = stores.createProject(.init(name: "Other", workspaceId: "other", path: "/elsewhere"))
        let data = repository(stores, remote)
        try data.apply(populated(), workspaceId: workspace.id)
        try data.apply(empty(revision: 1, full: false), workspaceId: workspace.id)
        XCTAssertEqual(data.revision, 1, "An unchanged poll must not restart chat rendering")
        try data.apply(empty(revision: 2, full: false, deleted: [
            .init(kind: "projects", id: "project", revision: 2),
            .init(kind: "chats", id: "chat", revision: 2)
        ]), workspaceId: workspace.id)
        XCTAssertNotNil(stores.agents.get("agent"))
        XCTAssertNil(stores.projects.get("project"))
        XCTAssertNil(stores.chats.get("chat"))
        XCTAssertEqual(stores.projects.get(other.id), other)
    }

    func testInvalidSnapshotCannotPartiallyReplaceCache() throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        let data = repository(stores, remote)
        try data.apply(populated(), workspaceId: workspace.id)
        var invalid = populated(revision: 2)
        invalid.agents[0].name = "Must not be applied"
        invalid.projects = []
        XCTAssertThrowsError(try data.apply(invalid, workspaceId: workspace.id))
        XCTAssertEqual(stores.agents.get("agent")?.name, "Codex")
        XCTAssertNotNil(stores.projects.get("project"))
        XCTAssertEqual(data.revision, 1)
    }

    func testProjectWritesRequireDaemonAndNetworkFailureKeepsCache() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = empty()
        let data = repository(stores, remote)
        remote.prepareError = WorkspaceRegistryError.updateRequired
        let input = CreateProjectInput(name: "Local legacy", workspaceId: workspace.id, path: "/work/legacy")
        do { _ = try await data.createProject(input); XCTFail("Project creation must never fall back to a local write") } catch {}
        XCTAssertTrue(stores.projects.list().isEmpty)
        let legacy = stores.createProject(input) // Existing data from a previous app version.
        XCTAssertNotNil(stores.projects.get(legacy.id))
        remote.prepareError = nil
        remote.current = populated()
        await data.refresh(workspace)
        XCTAssertNil(data.errors[workspace.id])

        remote.prepareError = URLError(.notConnectedToInternet)
        await data.refresh(workspace)
        XCTAssertNotNil(stores.projects.get("project"))
        remote.prepareError = WorkspaceRegistryError.updateRequired
        do { _ = try await data.createProject(input); XCTFail("A migrated cache cannot become authoritative again") }
        catch {}
        XCTAssertEqual(stores.projects.list().map(\.id), ["project"])
    }

    func testLostCreateAcknowledgmentReusesIDAndOnlyPublishesServerSnapshot() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = empty()
        remote.supportsProjectOperations = true
        remote.onStart = { request in
            let project = Project(id: request.id, name: request.name, workspaceId: "database", path: request.path,
                                  createdAt: "2026-09-16T00:00:00Z", revision: 1)
            remote.current = WorkspaceMetadata(version: 1, workspaceId: "database", revision: 1, full: true,
                                               agents: [], projects: [project], chats: [], deleted: [])
            let operation = ProjectOperation(id: request.id, source: request.source, name: request.name, path: request.path,
                status: "succeeded", phase: "complete", projectId: request.id, createdAt: project.createdAt,
                updatedAt: project.createdAt, sequence: 3, attempt: 1)
            remote.operations = [operation]
            if remote.startIDs.count == 1 { throw URLError(.networkConnectionLost) }
            return operation
        }
        let data = repository(stores, remote)
        let input = CreateProjectInput(name: "New app", workspaceId: workspace.id, path: "/work/new")
        do { _ = try await data.createProject(input); XCTFail("Expected lost acknowledgment") } catch {}
        XCTAssertTrue(stores.projects.list().isEmpty)
        let reopened = repository(stores, remote) // The stable request ID survives an app restart.
        let saved = try await reopened.createProject(input)
        XCTAssertEqual(remote.startIDs.count, 2)
        XCTAssertEqual(remote.startIDs[0], remote.startIDs[1], "A retry must not create a second project")
        XCTAssertEqual(stores.projects.list(), [saved])
        XCTAssertEqual(saved.revision, 1)
        XCTAssertNotEqual(reopened.projectRequestID(workspaceId: workspace.id, source: "folder", name: input.name, path: input.path),
                          remote.startIDs.last, "A later explicit creation must not reuse a completed/tombstoned intent")
    }

    func testFolderRemovalUsesConfirmedRevisionAndOnlyDaemonSnapshotRemovesCache() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        remote.current = populated()
        let data = repository(stores, remote)
        await data.refresh(workspace)
        remote.onRemove = { id, request in
            XCTAssertEqual(id, "project")
            XCTAssertEqual(request.expectedRevision, 1)
            let operation = ProjectOperation(id: request.operationId, source: "delete", name: "App", path: "/work/app",
                expectedRevision: request.expectedRevision, status: "running", phase: "removing", projectId: id,
                createdAt: self.workspace.createdAt, updatedAt: self.workspace.createdAt, sequence: 1, attempt: 1)
            remote.operations = [operation]
            if remote.removeIDs.count == 1 { throw URLError(.networkConnectionLost) }
            return operation
        }
        do { _ = try await data.removeProjectFiles("project"); XCTFail("Expected lost acknowledgement") } catch {}
        XCTAssertNotNil(stores.projects.get("project"))
        XCTAssertEqual(stores.chats.get("chat")?.sessionId, "native-session")
        let reopened = repository(stores, remote)
        let operation = try await reopened.removeProjectFiles("project")
        XCTAssertEqual(remote.removeIDs.count, 2)
        XCTAssertEqual(remote.removeIDs[0], remote.removeIDs[1])
        XCTAssertNotNil(stores.projects.get("project"), "An accepted operation is not a completed deletion")
        remote.operations[0].status = "succeeded"; remote.operations[0].phase = "complete"; remote.operations[0].sequence = 3
        remote.current = empty(revision: 2, deleted: [
            .init(kind: "projects", id: "project", revision: 2), .init(kind: "chats", id: "chat", revision: 2)
        ])
        let result = try await reopened.observeProject(operation.id, workspaceId: workspace.id) { _ in }
        XCTAssertTrue(result.removesFiles)
        XCTAssertFalse(result.canStop)
        XCTAssertEqual(result.phaseLabel, "Folder deleted")
        XCTAssertNil(stores.projects.get("project"))
        XCTAssertNil(stores.chats.get("chat"))
    }

    func testMetadataOnlyRemovalWaitsForDaemonAndReconcilesOtherAppCaches() async throws {
        let first = try stores(), second = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        remote.current = populated()
        let a = repository(first, remote), b = repository(second, remote)
        await a.refresh(workspace)
        await b.refresh(workspace)
        var attempts = 0
        remote.onDelete = { kind, id, revision in
            XCTAssertEqual(kind, "projects")
            XCTAssertEqual(id, "project")
            XCTAssertEqual(revision, 1)
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            XCTAssertNotNil(first.projects.get(id), "Do not remove the cache before daemon acknowledgement")
            remote.current = self.empty(revision: 2, deleted: [
                .init(kind: "projects", id: id, revision: 2), .init(kind: "chats", id: "chat", revision: 2)
            ])
            remote.current.agents = self.populated().agents
            return remote.current
        }
        do { try await a.removeProject("project"); XCTFail("Expected lost connection") } catch {}
        XCTAssertNotNil(first.projects.get("project"))
        XCTAssertNotNil(first.chats.get("chat"))
        try await a.removeProject("project")
        XCTAssertNil(first.projects.get("project"))
        XCTAssertNil(first.chats.get("chat"))
        XCTAssertNotNil(first.agents.get("agent"))
        XCTAssertTrue(remote.removeIDs.isEmpty, "Keeping files must never call the filesystem deletion endpoint")
        await b.refresh(workspace)
        XCTAssertNil(second.projects.get("project"))
        XCTAssertNil(second.chats.get("chat"))
        XCTAssertNotNil(second.agents.get("agent"))
        XCTAssertNil(Stores(defaults: first.defaults).projects.get("project"), "Removal must survive app relaunch")
    }

    func testFileRemovalCannotDeleteADifferentFolderAfterConfirmation() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        remote.current = populated()
        let data = repository(stores, remote)
        await data.refresh(workspace)
        let confirmed = try XCTUnwrap(stores.projects.get("project"))
        remote.current = populated(revision: 2)
        remote.current.projects[0].path = "/work/another-folder"
        await data.refresh(workspace)
        do {
            _ = try await data.removeProjectFiles("project", confirmed: confirmed)
            XCTFail("The confirmation only authorized the previous folder")
        } catch { XCTAssertEqual(error.localizedDescription, t("project.removeChanged")) }
        XCTAssertTrue(remote.removeIDs.isEmpty)
        XCTAssertEqual(stores.projects.get("project")?.path, "/work/another-folder")
    }

    func testCreationCompletedWhileAppWasClosedDoesNotReuseItsDeletedID() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        let data = repository(stores, remote)
        let id = data.projectRequestID(workspaceId: workspace.id, source: "create", name: "App", path: "/work/app")
        var completed = populated()
        completed.projects = [Project(id: id, name: "App", workspaceId: "database", path: "/work/app", createdAt: workspace.createdAt, revision: 1)]
        completed.chats = []
        remote.current = completed
        let reopened = repository(stores, remote)
        await reopened.refresh(workspace)
        XCTAssertNotNil(stores.projects.get(id))
        remote.current = empty(revision: 2, deleted: [.init(kind: "projects", id: id, revision: 2)])
        await reopened.refresh(workspace)
        XCTAssertNil(stores.projects.get(id))
        XCTAssertNotEqual(reopened.projectRequestID(workspaceId: workspace.id, source: "create", name: "App", path: "/work/app"), id)
    }

    func testFreshClientRestoresRunningOperationAndDetachingDoesNotCancelIt() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        let operation = ProjectOperation(id: "clone", source: "clone", name: "App", path: "/work/app",
            repoUrl: "https://github.com/owner/repo.git", status: "running", phase: "receiving", progress: 0.42,
            log: "Receiving objects: 42%", createdAt: workspace.createdAt, updatedAt: workspace.createdAt, sequence: 4, attempt: 1)
        remote.operations = [operation]
        let data = repository(stores, remote)
        await data.refresh(workspace)
        XCTAssertEqual(data.cachedProjectOperation("clone", workspaceId: workspace.id), operation)
        var received: ProjectOperation?
        let watching = Task { try await data.observeProject("clone", workspaceId: workspace.id) { received = $0 } }
        for _ in 0..<100 where received == nil { await Task.yield() }
        XCTAssertEqual(received?.progress, 0.42, "Reopening starts from the current snapshot")
        watching.cancel()
        do { _ = try await watching.value; XCTFail("Expected observer cancellation") } catch {}
        XCTAssertEqual(remote.cancelCalls, 0)
        XCTAssertEqual(remote.operations.first?.status, "running")
        XCTAssertTrue(stores.projects.list().isEmpty, "An active operation is not a completed project")
    }

    func testExplicitStopUsesDaemonAndRetainsOperationOutput() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        remote.operations = [.init(id: "clone", source: "clone", name: "App", path: "/work/app", status: "running",
            phase: "cloning", log: "Partial clone output", createdAt: workspace.createdAt, updatedAt: workspace.createdAt, sequence: 1, attempt: 1)]
        let data = repository(stores, remote)
        await data.refresh(workspace)
        try await data.cancelProjectOperation("clone", workspaceId: workspace.id)
        XCTAssertEqual(remote.cancelCalls, 1)
        XCTAssertEqual(data.cachedProjectOperation("clone", workspaceId: workspace.id)?.log, "Partial clone output")
        XCTAssertEqual(data.cachedProjectOperation("clone", workspaceId: workspace.id)?.status, "cancelled")
    }

    func testLateSnapshotAfterWorkspaceDeletionCannotResurrectItsChildren() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = populated()
        remote.holdSnapshot = true
        let data = repository(stores, remote)
        let refresh = Task { await data.refresh(workspace) }
        for _ in 0..<100 where remote.snapshotGate == nil { await Task.yield() }
        XCTAssertNotNil(remote.snapshotGate)
        stores.cascadeProjects(forWorkspaceId: workspace.id)
        data.forget(workspace.id)
        remote.releaseSnapshot()
        await refresh.value
        XCTAssertTrue(stores.agents.list().isEmpty)
        XCTAssertTrue(stores.projects.list().isEmpty)
        XCTAssertTrue(stores.chats.list().isEmpty)
        XCTAssertNil(data.errors[workspace.id])
    }

    func testRegistryReplacementUsesFullSnapshotAndNeverImportsOldCache() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = populated()
        let data = repository(stores, remote)
        await data.refresh(workspace)
        remote.deltaError = DaemonHTTPError(status: 409, message: "registry replaced")
        remote.current = .init(version: 1, workspaceId: "new-database", revision: 0, full: true,
                               agents: [], projects: [], chats: [], deleted: [])
        await data.refresh(workspace)
        XCTAssertNil(data.errors[workspace.id])
        XCTAssertEqual(remote.snapshotCalls, 2)
        XCTAssertTrue(remote.imports.isEmpty)
        XCTAssertTrue(stores.projects.list().isEmpty)
    }

    func testEarlierDatabaseBackupRepairsCacheFromFullSnapshot() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.current = populated(revision: 10)
        let data = repository(stores, remote)
        await data.refresh(workspace)
        remote.deltaError = DaemonHTTPError(status: 409, message: "cursor is ahead of restored backup")
        remote.current = empty()
        await data.refresh(workspace)
        XCTAssertNil(data.errors[workspace.id])
        XCTAssertTrue(stores.projects.list().isEmpty)
        XCTAssertTrue(remote.imports.isEmpty)
    }
    func testAcceptedSubmissionSurvivesRelaunchAndBecomesOneProjectRow() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        let data = repository(stores, remote)
        remote.onStart = { request in
            let operation = ProjectOperation(id: request.id, source: request.source, name: request.name, path: request.path,
                status: "running", phase: "cloning", progress: 0.1, createdAt: self.workspace.createdAt,
                updatedAt: self.workspace.createdAt, sequence: 1, attempt: 1)
            remote.operations = [operation]
            return operation
        }
        let model = ProjectCreationModel()
        let accepted = await model.submit(data: data, workspaceId: workspace.id) {
            .init(id: "new-project", source: "clone", name: "New project", path: "/work/new-project")
        }
        XCTAssertEqual(accepted?.status, "running", "The form finishes on acknowledgement, without waiting for the clone")
        XCTAssertFalse(model.isSubmitting)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(stores.projects.list().isEmpty, "Pending work must not invent an authoritative Project")
        let initial = ProjectListEntry.merge(projects: [], operations: data.projectOperations)
        XCTAssertEqual(initial.count, 1)
        let rowID = try XCTUnwrap(initial.first?.id)

        let reopened = repository(stores, remote)
        XCTAssertEqual(reopened.cachedProjectOperation("new-project", workspaceId: workspace.id), accepted)
        remote.prepareError = URLError(.notConnectedToInternet)
        await reopened.refresh(workspace)
        XCTAssertNotNil(reopened.errors[workspace.id])
        XCTAssertEqual(ProjectListEntry.merge(projects: [], operations: reopened.projectOperations).first?.id, rowID)

        remote.prepareError = nil
        remote.operations[0].status = "succeeded"
        remote.operations[0].phase = "complete"
        remote.operations[0].sequence = 5
        remote.operations[0].projectId = "new-project"
        remote.current = empty(revision: 1)
        remote.current.projects = [.init(id: "new-project", name: "New project", workspaceId: "database",
            path: "/work/new-project", createdAt: workspace.createdAt, revision: 1)]
        await reopened.refresh(workspace)
        let ready = ProjectListEntry.merge(projects: stores.projects.list(), operations: reopened.projectOperations)
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.id, rowID)
        XCTAssertNotNil(ready.first?.project)
        XCTAssertNil(ready.first?.operation, "The pending row becomes the normal project row")

        remote.current = empty(revision: 2, deleted: [.init(kind: "projects", id: "new-project", revision: 2)])
        await reopened.refresh(workspace)
        XCTAssertTrue(ProjectListEntry.merge(projects: stores.projects.list(), operations: reopened.projectOperations).isEmpty,
                      "Old successful operations must not resurrect a subsequently removed project")
        let thirdLaunch = repository(stores, remote)
        XCTAssertTrue(thirdLaunch.projectOperations.values.flatMap { $0 }.isEmpty)
    }

    func testUnsupportedDaemonRejectsBeforeAcquiringCredentialsOrShowingCreation() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        let data = repository(stores, remote)
        try data.apply(populated(), workspaceId: workspace.id)
        let model = ProjectCreationModel()
        var acquiredCredentials = false
        let result = await model.submit(data: data, workspaceId: workspace.id) {
            acquiredCredentials = true
            return .init(id: "new", source: "clone", name: "New", path: "/work/new")
        }
        XCTAssertNil(result)
        XCTAssertFalse(acquiredCredentials)
        XCTAssertTrue(remote.startIDs.isEmpty)
        XCTAssertTrue(data.projectOperations.isEmpty)
        XCTAssertNotNil(stores.projects.get("project"))
        XCTAssertEqual(model.errorMessage, WorkspaceRegistryError.updateRequired.localizedDescription)
    }

    func testCompletedOperationStaysVisibleUntilMetadataCanBeReconciled() async throws {
        let stores = try stores(), remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        let data = repository(stores, remote)
        remote.onStart = { request in
            let result = ProjectOperation(id: request.id, source: "folder", name: request.name, path: request.path,
                status: "succeeded", phase: "complete", projectId: request.id, createdAt: self.workspace.createdAt,
                updatedAt: self.workspace.createdAt, sequence: 4, attempt: 1)
            remote.operations = [result]
            remote.deltaError = URLError(.networkConnectionLost)
            return result
        }
        _ = try await data.startProject(.init(id: "pending", source: "folder", name: "Folder", path: "/work/folder"), workspaceId: workspace.id)
        await data.refresh(workspace)
        XCTAssertNotNil(data.errors[workspace.id])
        let entries = ProjectListEntry.merge(projects: stores.projects.list(), operations: data.projectOperations)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.statusLabel, t("project.operation.phase.registering"))
        let reopened = repository(stores, remote)
        XCTAssertEqual(reopened.cachedProjectOperation("pending", workspaceId: workspace.id)?.status, "succeeded")
        data.forget(workspace.id)
        XCTAssertTrue(repository(stores, remote).projectOperations.isEmpty)
    }

    func testProjectRowsUseLatestOperationAndDoNotDuplicateAnExistingFolder() {
        let project = populated().projects[0]
        let running = ProjectOperation(id: "another-request", source: "folder", name: "App", path: project.path,
            status: "running", phase: "preparing", createdAt: workspace.createdAt, updatedAt: workspace.createdAt, sequence: 1, attempt: 1)
        let rows = ProjectListEntry.merge(projects: [project], operations: ["database": [running]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.project?.id, project.id)
        XCTAssertEqual(rows.first?.reference?.operationId, running.id)
        XCTAssertEqual(rows.first?.statusLabel, t("project.operation.creating"))
    }
}

/// Scripted transport: tests choose authoritative replies and failures at the network boundary.
@MainActor
final class WorkspaceRemoteFixture: WorkspaceRegistryRemote {
    var supportsAgentDiscovery = false
    var ensure: ((AgentID, String) async throws -> WorkspaceEnsureAgentResult)?
    func ensureAgent(type: AgentID, name: String) async throws -> WorkspaceEnsureAgentResult {
        guard let ensure else { throw WorkspaceRegistryError.updateRequired }
        return try await ensure(type, name)
    }
    var supportsProjectLibrary = false
    var readLibrary: (() async throws -> DaemonProjectLibrary)?
    var editLibrary: ((ProjectLibraryEdit) async throws -> DaemonProjectLibrary)?
    func projectLibrary() async throws -> DaemonProjectLibrary {
        guard let readLibrary else { throw WorkspaceRegistryError.projectLibraryUnavailable }
        return try await readLibrary()
    }
    func editProjectLibrary(_ edit: ProjectLibraryEdit) async throws -> DaemonProjectLibrary {
        guard let editLibrary else { throw WorkspaceRegistryError.projectLibraryUnavailable }
        return try await editLibrary(edit)
    }
    var browseConversations: ((ConversationQuery) async throws -> ConversationPage)?
    var resolveConversation: ((ConversationOpenRequest) async throws -> ConversationOpenResult)?
    func conversations(_ query: ConversationQuery) async throws -> ConversationPage {
        guard let browseConversations else { throw WorkspaceRegistryError.conversationBrowserUnavailable }
        return try await browseConversations(query)
    }
    func openConversation(_ request: ConversationOpenRequest) async throws -> ConversationOpenResult {
        guard let resolveConversation else { throw WorkspaceRegistryError.conversationBrowserUnavailable }
        return try await resolveConversation(request)
    }
    var sessionRefreshFlags: [Bool] = []
    var gitOperationsProvider: ((Int) async throws -> DaemonHTTP?)?
    var gitAccessProvider: (() async throws -> DaemonHTTP)?
    var supportsProjectOperations = false
    var supportsProjectIcons = false
    var supportsGitAccess = false
    var supportsNotificationPreferences = false
    var prepareAllowInstall: [Bool] = []
    var startIDs: [String] = []
    var onStart: ((ProjectCreateRequest) throws -> ProjectOperation)?
    var operations: [ProjectOperation] = []
    var removeIDs: [String] = []
    var onRemove: ((String, ProjectRemoveRequest) throws -> ProjectOperation)?
    var cancelCalls = 0
    var current = WorkspaceMetadata(version: 1, workspaceId: "database", revision: 0, full: true,
                                    agents: [], projects: [], chats: [], deleted: [])
    var prepareError: Error?
    var prepareCalls = 0
    var invalidateCalls = 0
    var deltaError: Error?
    var failImportCall: Int?
    var imports: [WorkspaceLegacyImport] = []
    var snapshotCalls = 0
    var snapshotError: Error?
    var putIDs: [String] = []
    var holdSnapshot = false
    var snapshotGate: CheckedContinuation<Void, Never>?
    var holdChanges = false
    var changesGate: CheckedContinuation<Void, Never>?
    var onPut: ((String, String, Data, Int64?) throws -> WorkspaceMetadata)?
    var onDelete: ((String, String, Int64?) throws -> WorkspaceMetadata)?

    func invalidateChecks() { invalidateCalls += 1 }
    func gitHTTP() async throws -> DaemonHTTP {
        guard let gitAccessProvider else { throw WorkspaceRegistryError.gitAccessUnavailable }
        return try await gitAccessProvider()
    }
    func gitOperationsHTTP(minimumVersion: Int) async throws -> DaemonHTTP? {
        if let gitOperationsProvider { return try await gitOperationsProvider(minimumVersion) }
        if minimumVersion > 1 { throw WorkspaceRegistryError.gitOperationsUnavailable(minimumVersion: minimumVersion) }
        return nil
    }
    func prepare(allowInstall: Bool) async throws {
        prepareCalls += 1
        prepareAllowInstall.append(allowInstall)
        if let prepareError { throw prepareError }
    }
    func snapshot() async throws -> WorkspaceMetadata {
        snapshotCalls += 1
        if holdSnapshot { await withCheckedContinuation { snapshotGate = $0 } }
        if let snapshotError { throw snapshotError }
        return current
    }
    func snapshot(refreshSessions: Bool) async throws -> WorkspaceMetadata {
        sessionRefreshFlags.append(refreshSessions)
        return try await snapshot()
    }
    func releaseSnapshot() { holdSnapshot = false; snapshotGate?.resume(); snapshotGate = nil }
    func changes(since: Int64, identity: String) async throws -> WorkspaceMetadata {
        if holdChanges { await withCheckedContinuation { changesGate = $0 } }
        if let deltaError { throw deltaError }
        return current
    }
    func changes(since: Int64, identity: String, refreshSessions: Bool) async throws -> WorkspaceMetadata {
        sessionRefreshFlags.append(refreshSessions)
        return try await changes(since: since, identity: identity)
    }
    func releaseChanges() { holdChanges = false; changesGate?.resume(); changesGate = nil }
    func importLegacy(_ records: WorkspaceLegacyImport) async throws -> WorkspaceMetadata {
        imports.append(records)
        if failImportCall == imports.count { throw URLError(.networkConnectionLost) }
        return current
    }
    func put(kind: String, id: String, record: Data, revision: Int64?) async throws -> WorkspaceMetadata {
        putIDs.append(id)
        return try onPut?(kind, id, record, revision) ?? current
    }
    func delete(kind: String, id: String, revision: Int64?) async throws -> WorkspaceMetadata {
        try onDelete?(kind, id, revision) ?? current
    }
    func dispose() async {}
    func startProject(_ request: ProjectCreateRequest) async throws -> ProjectOperation {
        startIDs.append(request.id)
        guard let onStart else { throw WorkspaceRegistryError.updateRequired }
        return try onStart(request)
    }
    func projectOperations() async throws -> [ProjectOperation] { operations }
    func removeProjectFiles(_ id: String, request: ProjectRemoveRequest) async throws -> ProjectOperation {
        removeIDs.append(request.operationId)
        guard let onRemove else { throw WorkspaceRegistryError.updateRequired }
        return try onRemove(id, request)
    }
    func projectOperation(_ id: String) async throws -> ProjectOperation { try XCTUnwrap(operations.first { $0.id == id }) }
    func cancelProjectOperation(_ id: String) async throws -> ProjectOperation {
        cancelCalls += 1
        let index = try XCTUnwrap(operations.firstIndex { $0.id == id })
        operations[index].status = "cancelled"; operations[index].sequence += 1
        return operations[index]
    }
}
