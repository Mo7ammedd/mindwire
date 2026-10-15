import Foundation
import Observation
import OblienKit

/// The same disk records and permissions are used by creation and workspace management.
struct WorkspaceCreationAttachment: Identifiable {
    var disk: WorkspaceManagedDisk
    var mountPath = ""
    var target = "local"
    var readOnly = false
    var id: String { disk.id }

    var sdkValue: WorkspaceDiskAttachment {
        .init(diskId: disk.id, mountPath: disk.format == "ext4" ? mountPath.nonBlank : nil,
              readOnly: disk.isReadOnly || readOnly, role: disk.kind == "root" ? "layer" : nil,
              target: disk.format == "raw" ? target : nil)
    }
}

@MainActor @Observable
final class WorkspaceCreationStorage {
    struct Namespace: Identifiable {
        let id: String
        let name: String
    }
    var namespace = ""
    var root: WorkspaceManagedDisk?
    var attachments: [WorkspaceCreationAttachment] = []
    let disks = WorkspaceControlValue<[WorkspaceManagedDisk]>()
    let namespaces = WorkspaceControlValue<[Namespace]>()

    var summary: String {
        let source = root?.displayName ?? "New root"
        return attachments.isEmpty ? source : "\(source) · \(attachments.count) additional"
    }

    func load(force: Bool = false) async {
        async let diskRead: Void = disks.load(force: force) {
            try await OblienCloud.client.disks.list().map(WorkspaceManagedDisk.init)
        }
        async let namespaceRead: Void = namespaces.load(force: force) {
            var result: [Namespace] = []
            var offset = 0
            while true {
                let page = try await OblienCloud.client.namespaces.list(.init(limit: 100, offset: offset, status: .active))
                result += page.data.map { .init(id: $0.slug, name: $0.name) }
                offset += page.data.count
                if page.data.isEmpty || offset >= page.pagination.total { break }
            }
            return result
        }
        _ = await (diskRead, namespaceRead)
        if let updated = disks.value?.first(where: { $0.id == root?.id }) { root = updated }
        for index in attachments.indices {
            if let updated = disks.value?.first(where: { $0.id == attachments[index].id }) { attachments[index].disk = updated }
        }
    }

    func validation(image: WorkspaceImage?) -> String? {
        if let root {
            guard root.canCreateWorkspace, root.namespace?.nonBlank == namespace.nonBlank else {
                return "Choose an available root disk in this namespace. Saved roots can be forked from Disks & Software."
            }
            if disks.loaded, disks.value?.contains(where: { $0.id == root.id }) != true {
                return "The selected root disk is no longer available. Choose another disk."
            }
        }
        var paths = Set<String>()
        for attachment in attachments {
            let disk = attachment.disk
            guard disk.id != root?.id, disk.canAttachToNewWorkspace(image: root?.rootImage ?? image?.image, namespace: namespace.nonBlank) else {
                return "“\(disk.displayName)” cannot be attached to this workspace. Check its namespace, image, and current attachments."
            }
            if disks.loaded, disks.value?.contains(where: { $0.id == disk.id }) != true {
                return "“\(disk.displayName)” is no longer available. Remove it or choose another disk."
            }
            if disk.format == "raw" {
                let targets = image?.diskTargets ?? []
                guard attachment.target == "local" || targets.contains(where: { $0.id == attachment.target && $0.formats.contains("raw") }) else {
                    return "Choose a supported runtime for “\(disk.displayName)”."
                }
            } else if disk.kind != "root", let path = attachment.mountPath.nonBlank {
                guard WorkspaceControlValidation.mountPath(path), paths.insert(path).inserted else {
                    return "Use a different absolute mount directory for each disk."
                }
            }
        }
        return nil
    }
}

extension WorkspaceManagedDisk {
    var canCreateWorkspace: Bool {
        kind == "root" && !isReadOnly && connections.isEmpty && permits("create_workspace")
    }
    func canAttachToNewWorkspace(image: String?, namespace: String?) -> Bool {
        permits("attach") && self.namespace?.nonBlank == namespace?.nonBlank &&
        (isReadOnly || connections.isEmpty) &&
        (kind == "data" || (kind == "root" && isReadOnly && rootImage != nil && rootImage == image))
    }
}
