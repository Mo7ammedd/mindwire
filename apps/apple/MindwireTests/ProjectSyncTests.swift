import XCTest
import CryptoKit
import SwiftUI
@testable import Mindwire

@MainActor
final class ProjectSyncTests: XCTestCase {
    private func stores() throws -> Stores {
        let suite = "project-sync-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func project(_ id: String = "source", workspace: String = "X") -> Project {
        .init(id: id, name: "Example", workspaceId: workspace, path: "/projects/example", createdAt: isoNow(), syncId: "logical-project")
    }

    private func awaitResult(_ coordinator: ProjectSyncCoordinator, _ id: String) async throws -> ProjectTransfer {
        for _ in 0..<1_000 {
            if let value = coordinator.transfers[id], !value.active { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Transfer did not settle")
        throw URLError(.timedOut)
    }

    private func remotePair() -> (SyncRemoteFixture, SyncRemoteFixture) {
        let source = SyncRemoteFixture(), target = SyncRemoteFixture()
        source.chunks = ["chunk-one": Data("one".utf8), "chunk-two": Data("two".utf8)]
        source.checkpoints["checkpoint"] = .init(id: "checkpoint", projectId: "logical-project", parents: [],
            manifest: .init(kind: "file", mode: 384, size: 6, chunks: ["chunk-one", "chunk-two"]), objectCount: 2, bytes: 6)
        return (source, target)
    }

    func testLostChunkAcknowledgementRetriesOnlyMissingDataAndCoalescesStart() async throws {
        let stores = try stores(), project = project()
        stores.projects.save(project)
        let (source, target) = remotePair()
        target.dropPutAcknowledgement = true
        var reconciles = 0, retries = 0
        let coordinator = ProjectSyncCoordinator(stores: stores, makeRemote: { $0 == "X" ? source : target }, reconcile: { _ in
            reconciles += 1
            stores.projects.save(self.project("replica", workspace: "Y"))
        }, retryDelay: { _ in retries += 1 })
        let token = String(repeating: "a", count: 64)
        let id = try coordinator.start(project: project, targetWorkspaceId: "Y", path: "/projects/example", includeIgnored: [".env"], selectionToken: token)
        let duplicate = try coordinator.start(project: project, targetWorkspaceId: "Y", path: "/projects/example", includeIgnored: [".env"], selectionToken: token)
        XCTAssertEqual(id, duplicate)
        XCTAssertThrowsError(try coordinator.start(project: project, targetWorkspaceId: "Y", path: "/projects/example", includeIgnored: ["node_modules"]))
        let result = try await awaitResult(coordinator, id)
        XCTAssertEqual(result.status, "succeeded")
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(source.exportIds, [id + "-export"])
        XCTAssertEqual(source.exportSelections, [[".env"]])
        XCTAssertEqual(source.exportTokens, [token])
        XCTAssertEqual(target.importSelections.first, [".env"])
        XCTAssertEqual(target.putIds.sorted(), ["chunk-one", "chunk-two"])
        XCTAssertEqual(Set(target.importIds), [id + "-import"])
        XCTAssertEqual(reconciles, 1)
        XCTAssertEqual(stores.projectsByRecency().map(\.id), ["replica"])
        XCTAssertNotNil(stores.projects.get("source"), "The source stays in the mobile cache as a preserved workspace copy")
        let reopened = Stores(defaults: stores.defaults)
        XCTAssertEqual(reopened.projectsByRecency().map(\.id), ["replica"])
        XCTAssertEqual(reopened.projectSync.transfers[id]?.status, "succeeded")
        XCTAssertEqual(reopened.projectSync.transfers[id]?.includeIgnored, [".env"])
        XCTAssertEqual(reopened.projectSync.transfers[id]?.selectionToken, token)
    }

    func testAcceptedDestinationResumesAfterRelaunchWithSourceOffline() async throws {
        let stores = try stores(), project = project()
        stores.projects.save(project)
        let (source, target) = remotePair()
        target.dropImportAcknowledgement = true
        let first = ProjectSyncCoordinator(stores: stores, makeRemote: { $0 == "X" ? source : target }, reconcile: { _ in },
            retryDelay: { _ in throw CancellationError() })
        let id = try first.start(project: project, targetWorkspaceId: "Y", path: "/projects/example")
        let paused = try await awaitResult(first, id)
        XCTAssertEqual(paused.status, "paused")
        XCTAssertTrue(paused.didRelay)
        XCTAssertNil(paused.resultProjectId)
        let reopened = Stores(defaults: stores.defaults)
        var requested: [String] = []
        let resumed = ProjectSyncCoordinator(stores: reopened, makeRemote: { workspace in
            requested.append(workspace)
            guard workspace == "Y" else { throw URLError(.notConnectedToInternet) }
            return target
        }, reconcile: { _ in reopened.projects.save(self.project("replica", workspace: "Y")) }, retryDelay: { _ in })
        resumed.resumePending()
        let done = try await awaitResult(resumed, id)
        XCTAssertEqual(done.status, "succeeded")
        XCTAssertEqual(requested, ["Y"])
        XCTAssertEqual(Set(target.importIds), [id + "-import"])
        XCTAssertEqual(target.importCommits, 1, "Lost ACK must reuse the committed daemon operation")
    }

    func testConflictPreservesSourceSelectionAndNeverPublishesTarget() async throws {
        let stores = try stores(), project = project()
        stores.projects.save(project)
        let (source, target) = remotePair()
        target.importStatus = "conflicts"
        var reconciled = false
        let coordinator = ProjectSyncCoordinator(stores: stores, makeRemote: { $0 == "X" ? source : target }, reconcile: { _ in reconciled = true })
        let id = try coordinator.start(project: project, targetWorkspaceId: "Y", path: "/projects/example")
        let result = try await awaitResult(coordinator, id)
        XCTAssertEqual(result.status, "conflicts")
        XCTAssertEqual(result.operation?.conflicts?.first?.displayPath, "changed.swift")
        XCTAssertNil(result.resultProjectId)
        XCTAssertFalse(reconciled)
        XCTAssertEqual(stores.projectsByRecency().map(\.id), ["source"])
        XCTAssertEqual(source.cancelIds.count + target.cancelIds.count, 0)
    }

    func testCapabilityAndRegistryReplacementStopBeforeDestinationMutation() async throws {
        let stores = try stores(), project = project()
        stores.projects.save(project)
        let unavailable = ProjectSyncCoordinator(stores: stores, makeRemote: { _ in throw WorkspaceRegistryError.projectSyncUnavailable })
        let unavailableID = try unavailable.start(project: project, targetWorkspaceId: "Y", path: "/projects/example")
        let unavailableResult = try await awaitResult(unavailable, unavailableID)
        XCTAssertEqual(unavailableResult.status, "failed")
        XCTAssertEqual(unavailableResult.error, t("project.transfer.updateRequired"))

        var transfer = ProjectTransfer(id: "saved-intent", sourceProjectId: project.id, sourceWorkspaceId: "X", targetWorkspaceId: "Y",
                                       syncId: project.syncId, targetIdentity: "old-registry", checkpointId: "checkpoint", didRelay: true,
                                       status: "paused", createdAt: isoNow())
        transfer.destinationPath = "/projects/example"
        stores.defaults.set(try JSONEncoder().encode([transfer.id: transfer]), forKey: "mindwire:project-transfers:v1")
        try stores.workspaceData.apply(.init(version: 1, workspaceId: "new-registry", revision: 0, full: true,
                                             agents: [], projects: [], chats: [], deleted: []), workspaceId: "Y")
        let target = SyncRemoteFixture()
        let resumed = ProjectSyncCoordinator(stores: stores, makeRemote: { _ in target }, retryDelay: { _ in XCTFail("Identity errors must not retry") })
        resumed.resumePending()
        let result = try await awaitResult(resumed, transfer.id)
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.error, t("project.transfer.identityChanged"))
        XCTAssertTrue(target.importIds.isEmpty)
        XCTAssertTrue(target.putIds.isEmpty)
    }

    func testSyncTransportVerifiesChunksAndUsesUnscopedWorkspaceRoutes() async throws {
        let bytes = Data("verified file".utf8)
        let id = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let channel = SyncChannelFixture()
        channel.response = "{\"data\":\"\(bytes.base64EncodedString())\"}"
        let remote = ProjectSyncClient(http: DaemonHTTP(channel: channel, agentType: ""))
        let object = try await remote.object(id)
        XCTAssertEqual(object, bytes)
        XCTAssertEqual(channel.paths, ["/workspace/sync/objects/" + id])
        channel.response = "{\"data\":\"Y29ycnVwdA==\"}"
        do { _ = try await remote.object(id); XCTFail("Corrupt bytes must never be relayed") }
        catch { XCTAssertTrue(error is ProjectTransferError) }
        channel.response = "{\"version\":2,\"fileCount\":1,\"bytes\":5,\"ignoredCount\":1,\"ignored\":[{\"path\":\"node_modules\",\"kind\":\"directory\",\"included\":false}],\"includeIgnored\":[\".env\"],\"selectionToken\":\"\(String(repeating: "a", count: 64))\"}"
        let preview = try await remote.preview(projectId: "project", includeIgnored: [".env"], cursor: 0)
        XCTAssertEqual(preview.ignored.first?.path, "node_modules")
        XCTAssertEqual(channel.paths.last, "/workspace/sync/preview")
        let body = try XCTUnwrap(channel.bodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["includeIgnored"] as? [String], [".env"])
        XCTAssertEqual(json["projectId"] as? String, "project")
    }

    func testFileReviewCoalescesLoadsAndDiscardsAnOlderSelectionResponse() async throws {
        let remote = SyncRemoteFixture()
        var first: CheckedContinuation<ProjectSyncFilePreview, Never>?
        remote.previewHook = { paths, _ in
            if paths.isEmpty { return await withCheckedContinuation { first = $0 } }
            return remote.filePreview(paths)
        }
        let review = ProjectSyncFileReview(projectId: "source", makeRemote: { remote })
        review.refresh(); review.refresh()
        for _ in 0..<100 where first == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(remote.previewSelections.count, 1)
        XCTAssertFalse(review.ready)
        review.setIncluded(".env", true)
        for _ in 0..<100 where review.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(review.ready)
        XCTAssertEqual(review.preview?.includeIgnored, [".env"])
        let continuation = try XCTUnwrap(first)
        continuation.resume(returning: remote.filePreview([]))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(review.preview?.includeIgnored, [".env"], "An old response must not enable a different transfer scope")
        XCTAssertEqual(remote.exportIds, [])
        review.setIncluded("cache/fixtures/", true)
        review.setIncluded("cache", true)
        XCTAssertEqual(review.includeIgnored, [".env", "cache"])
        XCTAssertFalse(review.ready)
        for _ in 0..<100 where review.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(review.ready)
    }

    func testOlderPendingTransferRequiresReviewBeforeRelayingDependencyContent() async throws {
        let stores = try stores(), project = project()
        stores.projects.save(project)
        let transfer = ProjectTransfer(id: "legacy", sourceProjectId: project.id, sourceWorkspaceId: "X", targetWorkspaceId: "Y", status: "paused", createdAt: isoNow())
        stores.defaults.set(try JSONEncoder().encode([transfer.id: transfer]), forKey: "mindwire:project-transfers:v1")
        let (source,target) = remotePair()
        let coordinator = ProjectSyncCoordinator(stores: stores, makeRemote: { $0 == "X" ? source : target })
        coordinator.resumePending()
        let result = try await awaitResult(coordinator, transfer.id)
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.error, t("project.transfer.legacyReview"))
        XCTAssertTrue(source.exportIds.isEmpty)
        XCTAssertTrue(target.putIds.isEmpty)
        XCTAssertTrue(target.importIds.isEmpty)
    }

    func testFileReviewRequiresAValidAcknowledgementAndCanRecover() async throws {
        let remote = SyncRemoteFixture()
        remote.previewHook = { _, _ in throw URLError(.networkConnectionLost) }
        let review = ProjectSyncFileReview(projectId: "source", makeRemote: { remote })
        review.refresh()
        for _ in 0..<100 where review.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(review.ready); XCTAssertNotNil(review.error)
        remote.previewHook = nil
        review.refresh()
        for _ in 0..<100 where review.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(review.ready); XCTAssertNil(review.error)
        XCTAssertFalse(review.includes("node_modules"))
        XCTAssertEqual(remote.exportIds, [])
    }

    func testFileReviewShowsExclusionsAndSelectedWorkingSize() async throws {
        let remote = SyncRemoteFixture()
        let review = ProjectSyncFileReview(projectId: "source", makeRemote: { remote })
        review.refresh()
        for _ in 0..<100 where review.loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(review.ready)
        for scheme in [ColorScheme.dark, .light] {
            let host = UIHostingController(rootView: NavigationStack { ProjectSyncFileReviewScreen(review: review) }.preferredColorScheme(scheme))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(650))
            let image = ChatFeedSnapshot.image(host)
            let attachment = XCTAttachment(image: image); attachment.name = "project-sync-files-\(scheme)"; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-project-sync-files-\(scheme).png"))
            let text = try ChatFeedSnapshot.visibleText(in: image)
            XCTAssertTrue(text.contains("node_modules"), text)
            XCTAssertTrue(text.contains(".env"), text)
            XCTAssertTrue(text.contains("Working files"), text)
            XCTAssertTrue(text.contains("Include a Path"), text)
            window.isHidden = true
        }
    }
}

@MainActor
private final class SyncRemoteFixture: ProjectSyncRemote {
    var checkpoints: [String: ProjectSyncCheckpoint] = [:]
    var chunks: [String: Data] = [:]
    var operations: [String: ProjectSyncOperation] = [:]
    var exportIds: [String] = [], importIds: [String] = [], putIds: [String] = [], cancelIds: [String] = []
    var exportSelections: [[String]] = [], importSelections: [[String]] = [], previewSelections: [[String]] = []
    var exportTokens: [String?] = []
    var previewHook: (([String], Int) async throws -> ProjectSyncFilePreview)?
    var dropPutAcknowledgement = false, dropImportAcknowledgement = false
    var importStatus = "succeeded"
    var importCommits = 0
    func result(_ id: String, kind: String, status: String = "succeeded") -> ProjectSyncOperation {
        .init(id: id, kind: kind, status: status, phase: "complete", progress: 1, resultProjectId: "replica",
              resultCheckpointId: "checkpoint", recoveryCheckpointId: status == "conflicts" ? "recovery" : nil,
              conflicts: status == "conflicts" ? [.init(path: "files/changed.swift", kind: "file", message: "Both copies preserved")] : nil,
              createdAt: isoNow(), updatedAt: isoNow())
    }
    func filePreview(_ paths: [String]) -> ProjectSyncFilePreview {
        .init(version: 2, fileCount: 42, bytes: 184_320, ignoredCount: 3, ignored: [
            .init(path: ".env", kind: "file", included: paths.contains(".env")),
            .init(path: ".next", kind: "directory", included: paths.contains(".next")),
            .init(path: "node_modules", kind: "directory", included: paths.contains("node_modules"))
        ], includeIgnored: paths, next: nil, selectionToken: String(repeating: paths.isEmpty ? "a" : "b", count: 64))
    }
    func preview(projectId: String, includeIgnored: [String], cursor: Int) async throws -> ProjectSyncFilePreview {
        previewSelections.append(includeIgnored)
        if let previewHook { return try await previewHook(includeIgnored, cursor) }
        return filePreview(includeIgnored)
    }
    func export(id: String, projectId: String, includeIgnored: [String], selectionToken: String?) async throws -> ProjectSyncOperation {
        exportSelections.append(includeIgnored)
        exportTokens.append(selectionToken)
        exportIds.append(id); return result(id, kind: "export")
    }
    func importCheckpoint(id: String, checkpointId: String, path: String?, includeIgnored: [String], selectionToken: String?) async throws -> ProjectSyncOperation {
        importSelections.append(includeIgnored)
        importIds.append(id)
        if operations[id] == nil { operations[id] = result(id, kind: "import", status: importStatus); importCommits += 1 }
        if dropImportAcknowledgement { dropImportAcknowledgement = false; throw URLError(.networkConnectionLost) }
        return operations[id]!
    }
    func operation(_ id: String) async throws -> ProjectSyncOperation { operations[id] ?? result(id, kind: "import") }
    func retry(_ id: String) async throws -> ProjectSyncOperation { try await operation(id) }
    func cancel(_ id: String) async throws -> ProjectSyncOperation { cancelIds.append(id); return try await operation(id) }
    func checkpoint(_ id: String) async throws -> ProjectSyncCheckpoint {
        guard let value = checkpoints[id] else { throw DaemonHTTPError(status: 404, message: "Not found") }
        return value
    }
    func accept(_ checkpoint: ProjectSyncCheckpoint) async throws { checkpoints[checkpoint.id] = checkpoint }
    func objects(_ id: String, cursor: Int) async throws -> ProjectSyncObjectPage { .init(objects: chunks.keys.sorted(), next: nil) }
    func missing(_ objects: [String]) async throws -> [String] { objects.filter { chunks[$0] == nil } }
    func object(_ id: String) async throws -> Data { chunks[id]! }
    func putObject(_ id: String, data: Data) async throws {
        chunks[id] = data; putIds.append(id)
        if dropPutAcknowledgement { dropPutAcknowledgement = false; throw URLError(.networkConnectionLost) }
    }
}

@MainActor
private final class SyncChannelFixture: DaemonChannel {
    let label = "sync fixture"
    var response = "{}"
    var paths: [String] = []
    var bodies: [Data] = []
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        paths.append(path); if let jsonBody { bodies.append(jsonBody) }; return (200, response)
    }
}
