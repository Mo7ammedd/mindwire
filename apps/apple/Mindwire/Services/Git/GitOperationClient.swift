import Foundation

@MainActor
private enum GitSubmissions { static var active: Set<String> = [] }

/// A lost acknowledgement keeps the same ID across views and app launches.
/// Reconnection only observes; explicit retry can resubmit that exact intent.
@MainActor
struct GitOperationClient {
    let http: DaemonHTTP
    let workspaceId: String
    let registryId: String
    let projectId: String
    let receipts: JSONListStore<GitOperationReceipt>

    static func receipts(defaults: UserDefaults) -> JSONListStore<GitOperationReceipt> {
        JSONListStore(key: "mindwire:git-operation-receipts:v1", defaults: defaults)
    }

    var pending: GitOperationReceipt? {
        receipts.list().first { $0.workspaceId == workspaceId && $0.projectId == projectId }
    }

    func start(_ intent: GitOperationRequest,
               authorize: () async throws -> ProjectCloneAuth?) async throws -> GitOperation {
        let key = workspaceId + "\u{1f}" + projectId
        guard GitSubmissions.active.insert(key).inserted else { throw BackendError.message(t("git.operation.pending")) }
        defer { GitSubmissions.active.remove(key) }
        let wasPending = pending != nil
        let request: GitOperationRequest
        if let pending {
            guard pending.registryId == registryId else {
                receipts.remove(pending.id)
                throw BackendError.message(t("git.operation.workspaceChanged"))
            }
            guard pending.request.matches(intent) else { throw BackendError.message(t("git.operation.pending")) }
            request = pending.request
            do { return finish(try await get(request.id)) }
            catch let error as DaemonHTTPError where error.status == 404 { /* Same ID can be submitted again. */ }
        } else {
            request = intent
            save(request)
        }
        let auth: ProjectCloneAuth?
        do { auth = try await authorize() }
        catch {
            if !wasPending { receipts.remove(request.id) } // No write was submitted.
            throw error
        }
        guard var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] else {
            throw BackendError.message(t("git.operation.invalid"))
        }
        if let auth { body["auth"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth)) }
        do {
            let operation: GitOperation = try await http.decode("POST", "/workspace/projects/\(http.encQuery(projectId))/git/operations", json: body)
            guard operation.id == request.id, operation.projectId == projectId else {
                throw BackendError.message(t("git.operation.workspaceChanged"))
            }
            return finish(operation)
        } catch {
            // A timeout/decoding error can follow acceptance. Recover the saved
            // operation before considering a new request or reporting failure.
            if !Task.isCancelled, let operation = try? await get(request.id) { return finish(operation) }
            if !wasPending, let failure = error as? DaemonHTTPError,
               (400..<500).contains(failure.status), ![408, 429].contains(failure.status) {
                receipts.remove(request.id)
            }
            throw error
        }
    }

    func get(_ id: String) async throws -> GitOperation {
        let operation: GitOperation = try await http.decode("GET", "/workspace/git/operations/\(http.encQuery(id))", quiet: true)
        guard operation.id == id, operation.projectId == projectId else { throw BackendError.message(t("git.operation.workspaceChanged")) }
        return operation
    }

    func recover() async throws -> GitOperation? {
        if let pending {
            guard pending.registryId == registryId else {
                receipts.remove(pending.id)
                throw BackendError.message(t("git.operation.workspaceChanged"))
            }
            do { return finish(try await get(pending.id)) }
            catch let error as DaemonHTTPError where error.status == 404 {
                throw BackendError.message(t("git.operation.notAccepted"))
            }
        }
        struct Response: Decodable { let operations: [GitOperation] }
        let response: Response = try await http.decode("GET", "/workspace/projects/\(http.encQuery(projectId))/git/operations?active=true&actionsVersion=5", quiet: true)
        guard let operation = response.operations.first(where: \.isActive) else { return nil }
        if operation.isActive { save(operation.request) }
        return operation
    }

    func wait(_ initial: GitOperation, onChange: (GitOperation) -> Void) async throws -> GitOperation {
        var operation = initial
        try Task.checkCancellation()
        onChange(operation)
        if !operation.isActive { return finish(operation) }
        if let streaming = http.channel as? StreamingDaemonChannel {
            do {
                let path = http.scoped("/workspace/git/operations/\(http.encQuery(initial.id))/stream")
                for try await data in try await streaming.stream(method: "GET", path: path, jsonBody: nil) {
                    try Task.checkCancellation()
                    let next = try JSONDecoder().decode(GitOperation.self, from: data)
                    guard next.id == initial.id, next.projectId == projectId else {
                        throw BackendError.message(t("git.operation.workspaceChanged"))
                    }
                    guard next.sequence > operation.sequence else { continue }
                    operation = next
                    onChange(operation)
                    if !operation.isActive { return finish(operation) }
                }
            } catch {
                if Task.isCancelled || error.isRequestCancellation { throw error }
                // The stream only observes. Reconcile its durable receipt before
                // reporting a transport failure; never resubmit the Git write.
            }
            operation = try await get(initial.id)
            onChange(operation)
        }
        while operation.isActive {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            operation = try await get(operation.id)
            onChange(operation)
        }
        return finish(operation)
    }

    func cancel(_ id: String) async throws -> GitOperation {
        let operation: GitOperation = try await http.decode("POST", "/workspace/git/operations/\(http.encQuery(id))/cancel", json: [:])
        return finish(operation)
    }

    private func save(_ request: GitOperationRequest) {
        receipts.save(.init(workspaceId: workspaceId, registryId: registryId, projectId: projectId, request: request))
    }

    private func finish(_ operation: GitOperation) -> GitOperation {
        if !operation.isActive { receipts.remove(operation.id) }
        return operation
    }
}
