import Foundation

/// A presentation of a project and its latest daemon operation. Pending work never becomes a
/// locally invented Project record; its row keeps the project's identity when metadata arrives.
struct ProjectListEntry: Identifiable {
    let workspaceId: String
    let projectId: String
    var project: Project?
    var operation: ProjectOperation?
    var id: String { workspaceId + ":" + projectId }
    var name: String { project?.name ?? operation?.name ?? "" }
    var path: String { project?.path ?? operation?.path ?? "" }
    var date: String { project?.lastUsedAt ?? project?.createdAt ?? operation?.createdAt ?? "" }
    var reference: ProjectOperationReference? {
        operation.map { .init(workspaceId: workspaceId, operationId: $0.id) }
    }
    var statusLabel: String? {
        guard let operation else { return nil }
        if operation.status == "succeeded" { return t("project.operation.phase.registering") }
        if !operation.removesFiles && ["queued", "preparing"].contains(operation.phase) && operation.isActive {
            return t(operation.source == "clone" ? "project.operation.cloning" : "project.operation.creating")
        }
        return operation.phaseLabel
    }

    static func merge(projects: [Project], operations: [String: [ProjectOperation]]) -> [ProjectListEntry] {
        var entries = Dictionary(projects.map { project in
            let entry = ProjectListEntry(workspaceId: project.workspaceId, projectId: project.id, project: project)
            return (entry.id, entry)
        }, uniquingKeysWith: { _, last in last })
        for (workspaceId, operations) in operations {
            var seen: Set<String> = []
            var seenPaths: Set<String> = []
            for operation in operations.sorted(by: { ($0.updatedAt, $0.sequence) > ($1.updatedAt, $1.sequence) }) {
                guard seenPaths.insert(operation.path).inserted else { continue }
                let project = projects.first {
                    $0.workspaceId == workspaceId && ($0.id == (operation.projectId ?? operation.id) || $0.path == operation.path)
                }
                let projectId = project?.id ?? operation.projectId ?? operation.id
                let key = workspaceId + ":" + projectId
                guard seen.insert(key).inserted else { continue }
                if operation.status == "succeeded" && (project != nil || operation.removesFiles) { continue }
                if let project, operation.canRetry, !operation.removesFiles, project.id != (operation.projectId ?? operation.id) { continue }
                if operation.status == "cancelled" && project == nil { continue }
                entries[key] = .init(workspaceId: workspaceId, projectId: projectId, project: project, operation: operation)
            }
        }
        return entries.values.filter { !Project.isAssistantWorkspacePath($0.path) }
            .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }
}
