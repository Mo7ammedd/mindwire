import Foundation
import CryptoKit

@MainActor
protocol ProjectSyncRemote: AnyObject {
    func preview(projectId: String, includeIgnored: [String], cursor: Int) async throws -> ProjectSyncFilePreview
    func export(id: String, projectId: String, includeIgnored: [String], selectionToken: String?) async throws -> ProjectSyncOperation
    func importCheckpoint(id: String, checkpointId: String, path: String?, includeIgnored: [String], selectionToken: String?) async throws -> ProjectSyncOperation
    func operation(_ id: String) async throws -> ProjectSyncOperation
    func retry(_ id: String) async throws -> ProjectSyncOperation
    func cancel(_ id: String) async throws -> ProjectSyncOperation
    func checkpoint(_ id: String) async throws -> ProjectSyncCheckpoint
    func accept(_ checkpoint: ProjectSyncCheckpoint) async throws
    func objects(_ id: String, cursor: Int) async throws -> ProjectSyncObjectPage
    func missing(_ objects: [String]) async throws -> [String]
    func object(_ id: String) async throws -> Data
    func putObject(_ id: String, data: Data) async throws
}

struct ProjectSyncObjectPage: Codable { let objects: [String]; let next: Int? }

/// Only transport/encoding here. Native session interpretation and conflict
/// decisions remain in the workspace service, shared with the Go and TS SDKs.
@MainActor
final class ProjectSyncClient: ProjectSyncRemote {
    let http: DaemonHTTP
    private let base = "/workspace/sync"
    init(http: DaemonHTTP) { self.http = http }

    func preview(projectId: String, includeIgnored: [String], cursor: Int = 0) async throws -> ProjectSyncFilePreview {
        try await http.decode("POST", base + "/preview", json: ["projectId": projectId, "includeIgnored": includeIgnored, "cursor": cursor], quiet: true)
    }
    func export(id: String, projectId: String, includeIgnored: [String] = [], selectionToken: String? = nil) async throws -> ProjectSyncOperation {
        var json: [String: Any] = ["id": id, "projectId": projectId, "includeIgnored": includeIgnored]
        if let selectionToken { json["selectionToken"] = selectionToken }
        return try await http.decode("POST", base + "/exports", json: json, quiet: true)
    }
    func importCheckpoint(id: String, checkpointId: String, path: String?, includeIgnored: [String] = [], selectionToken: String? = nil) async throws -> ProjectSyncOperation {
        var json: [String: Any] = ["id": id, "checkpointId": checkpointId, "includeIgnored": includeIgnored]
        if let path { json["path"] = path }
        if let selectionToken { json["selectionToken"] = selectionToken }
        return try await http.decode("POST", base + "/imports", json: json, quiet: true)
    }
    func operation(_ id: String) async throws -> ProjectSyncOperation {
        try await http.decode("GET", base + "/operations/" + http.encQuery(id), quiet: true)
    }
    func retry(_ id: String) async throws -> ProjectSyncOperation {
        try await http.decode("POST", base + "/operations/" + http.encQuery(id) + "/retry", quiet: true)
    }
    func cancel(_ id: String) async throws -> ProjectSyncOperation {
        try await http.decode("POST", base + "/operations/" + http.encQuery(id) + "/cancel", quiet: true)
    }
    func checkpoint(_ id: String) async throws -> ProjectSyncCheckpoint {
        try await http.decode("GET", base + "/checkpoints/" + http.encQuery(id), quiet: true)
    }
    func accept(_ checkpoint: ProjectSyncCheckpoint) async throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint))
        let _: ProjectSyncCheckpoint = try await http.decode("PUT", base + "/checkpoints/" + http.encQuery(checkpoint.id), json: json, quiet: true)
    }
    func objects(_ id: String, cursor: Int) async throws -> ProjectSyncObjectPage {
        try await http.decode("GET", base + "/checkpoints/" + http.encQuery(id) + "/objects?cursor=\(cursor)", quiet: true)
    }
    func missing(_ objects: [String]) async throws -> [String] {
        struct Response: Decodable { let objects: [String] }
        let response: Response = try await http.decode("POST", base + "/objects/missing", json: ["objects": objects], quiet: true)
        guard Set(response.objects).isSubset(of: Set(objects)) else { throw ProjectTransferError.invalidData }
        return response.objects
    }
    func object(_ id: String) async throws -> Data {
        struct Response: Decodable { let data: Data }
        let response: Response = try await http.decode("GET", base + "/objects/" + http.encQuery(id), quiet: true)
        let checksum = SHA256.hash(data: response.data).map { String(format: "%02x", $0) }.joined()
        guard response.data.count <= 256 * 1024, checksum == id else { throw ProjectTransferError.invalidData }
        return response.data
    }
    func putObject(_ id: String, data: Data) async throws {
        let _: [String: Bool] = try await http.decode("PUT", base + "/objects/" + http.encQuery(id), json: ["data": data.base64EncodedString()], quiet: true)
    }
}
