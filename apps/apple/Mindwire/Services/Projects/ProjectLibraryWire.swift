import Foundation

struct DaemonProjectLibrary: Codable, Equatable {
    var version = 1
    var revision: Int64 = 0
    var folders: [ProjectFolder] = []
    var membership: [String: String] = [:]
    var order: [String] = []
}

struct ProjectLibraryPlacement: Codable, Equatable {
    let projectId: String
    let folderId: String?

    // Encode nil explicitly: it means remove from the group, not omit the edit.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(projectId, forKey: .projectId)
        try values.encode(folderId, forKey: .folderId)
    }
}

struct ProjectLibraryEdit: Codable, Equatable {
    var expectedRevision: Int64 = 0
    var folders: [ProjectFolder] = []
    var deleteFolders: [String] = []
    var placements: [ProjectLibraryPlacement] = []
    var order: [String] = []
    var folderOrder: [String] = []
    var importIfEmpty = false

    var isEmpty: Bool {
        folders.isEmpty && deleteFolders.isEmpty && placements.isEmpty && order.isEmpty && folderOrder.isEmpty
    }
}
