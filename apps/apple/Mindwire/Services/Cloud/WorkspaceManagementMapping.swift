import Foundation
import OblienKit

extension WorkspaceStatus {
    init(cloud value: OblienKit.Workspace) {
        let status = value.info?.status ?? value.status ?? value.resources?.status
        let preparation = value.provisioning.map {
            WorkspaceProvisioning(state: $0.state ?? "creating", phase: $0.phase, stage: $0.stage,
                                  message: $0.message, error: $0.error)
        }
        let power: WorkspacePower = preparation?.isPending == true ? .starting : preparation?.isFailed == true ? .stopped : WorkspacePower(status: status)
        let detail = preparation?.isPending == true ? "creating" : preparation?.isFailed == true ? "failed" : status
        self.init(power: power, detail: detail, provisioning: preparation)
    }
}

// Provider-neutral presentation values. Wire formats, authentication and API behavior belong
// to OblienKit; the app only adapts those typed results to its workspace capability contract.
extension ManagedWorkspace {
    init(_ value: OblienKit.Workspace) {
        self.init(id: value.id, name: value.name, slug: value.slug, logo: value.logo,
                  namespace: value.namespace, image: value.image, mode: value.mode?.rawValue,
                  info: .init(status: value.info?.status ?? value.status, isRunning: value.isRunning),
                  lifecycle: value.lifecycle.map(WorkspaceLifecycle.init), imageCapabilities: value.imageCapabilities,
                  resources: value.resources.map { .init(cpus: $0.cpus, memoryMb: $0.memoryMb, diskSizeMb: $0.diskSizeMb) },
                  createdAt: value.createdAt)
    }
}
extension WorkspaceLifecycle {
    init(_ value: OblienKit.Lifecycle) {
        self.init(mode: value.mode?.rawValue, status: value.status, pauseSupported: value.pauseSupported,
                  snapshotSupported: value.snapshotSupported, snapshotUnavailableReason: value.snapshotUnavailableReason,
                  restartPolicy: value.restartPolicy?.rawValue, maxRestarts: value.maxRestarts, ttl: value.ttl,
                  ttlAction: value.ttlAction?.rawValue, ttlExpiresAt: value.ttlExpiresAt, removeOnExit: value.removeOnExit,
                  idle: value.idle.map { .init(suspendAfter: $0.suspendAfter, stopAfter: $0.stopAfter,
                                             suspendAfterSeconds: $0.suspendAfterSeconds, stopAfterSeconds: $0.stopAfterSeconds) })
    }
}
extension WorkspaceNetwork {
    init(_ value: OblienKit.Network) {
        self.init(ip: value.ip, gateway: value.gateway, allowInternet: value.allowInternet, publicAccess: value.publicAccess,
                  ingressPorts: value.ingressPorts, egressPorts: value.egressPorts, egress: value.egress,
                  outboundIp: value.outboundIp, outboundCountryCode: value.outboundCountryCode, outboundMode: value.outboundMode,
                  outboundProxy: value.outboundProxy.map { .init(host: $0.host, port: $0.port, protocol: $0.protocol, hasCredentials: $0.hasCredentials) },
                  privateLinks: value.privateLinks?.map { .init(id: $0.id, workspaceId: $0.workspaceId, name: $0.name, ip: $0.ip) })
    }
}
extension WorkspaceNetworkPatch {
    var sdkValue: NetworkUpdateParams {
        .init(allowInternet: allowInternet, publicAccess: publicAccess, ingressPorts: ingressPorts, egress: egress,
              privateLinkIds: privateLinkIds, outboundMode: outboundMode,
              customProxy: customProxy.map { .init(host: $0.host, port: $0.port, protocol: $0.protocol, username: $0.username, password: $0.password) })
    }
}
extension WorkspaceManagedDisk {
    init(_ value: ManagedDisk) {
        self.init(id: value.id, name: value.name, namespace: value.namespace, state: value.state, kind: value.kind,
                  format: value.format, sizeMb: value.sizeMb, immutable: value.immutable, ownership: value.ownership,
                  rootImage: value.rootImage, operationId: value.operationId, permissions: value.permissions,
                  attachments: value.attachments?.map { .init(workspaceId: $0.workspaceId, mountPath: $0.mountPath, role: $0.role, target: $0.target, readOnly: $0.readOnly) })
    }
}
extension WorkspaceSoftware {
    init(_ value: SoftwareDisk) {
        self.init(id: value.id, name: value.name, label: value.label, description: value.description,
                  sizeMb: value.sizeMb, compatibleImages: value.compatibleImages,
                  attachment: value.attachment.map { .init(target: $0.target, role: $0.role, readOnly: $0.readOnly) })
    }
}
extension WorkspaceDiskOperation {
    init(_ value: DiskOperation) { self.init(id: value.id, state: value.state, phase: value.phase, error: value.error) }
}
extension WorkspaceDiskResult {
    init(_ value: DiskMutationResult) {
        self.init(disk: value.disk.map(WorkspaceManagedDisk.init), operation: value.operation.map(WorkspaceDiskOperation.init))
    }
}
extension WorkspaceDesktopInstallation {
    init(_ value: DesktopInstallation) {
        self.init(installable: value.installable, installed: value.installed, phase: value.phase, stage: value.stage, error: value.error,
                  choices: value.choices?.map { .init(id: $0.id, label: $0.label, description: $0.description, minimumMemoryMb: $0.minimumMemoryMb) },
                  workloadId: value.workloadId)
    }
}
extension WorkspaceManagedWorkload {
    init(_ value: Workload) throws {
        guard let id = value.id, !id.isEmpty else { throw WorkspaceControlError(message: "The workspace returned a process without an ID. Refresh and try again.") }
        self.init(id: id, name: value.name, state: value.state, status: value.status, command: value.command ?? value.cmd,
                  target: value.target, pid: value.pid ?? value.guestPid, restartPolicy: value.restartPolicy?.rawValue,
                  maxRestarts: value.maxRestarts, restartCount: value.restartCount, startedAt: value.startedAt, exitCode: value.exitCode,
                  origin: value.origin, workingDirectory: value.workingDir)
    }
}
extension WorkspaceWorkloadMetrics {
    init(_ value: WorkloadProcessStats) {
        self.init(id: value.id, state: value.state, cpuPercent: value.cpuPercent, memoryBytes: value.memoryBytes,
                  uptimeSeconds: value.uptimeSeconds, pid: value.pid, ports: value.ports)
    }
}
extension WorkspaceLogConfig {
    init(_ value: WorkloadLogConfig) {
        self.init(maxLogSizeMb: value.maxLogSizeMb, logRetentionHours: value.logRetentionHours,
                  storedBytes: value.storedBytes, droppedLines: value.droppedLines)
    }
}
extension WorkspaceLogEvent {
    init(_ value: LogBatch) {
        self.init(entries: value.entries.map { .init(line: $0.line, timestamp: $0.timestamp) }, cleared: value.cleared)
    }
}
extension WorkspaceSSHAccess {
    init(_ value: SSHStatus) {
        self.init(supported: value.supported, sshEnabled: value.sshEnabled, authMethods: value.authMethods,
                  passwordAuthEnabled: value.passwordAuthEnabled, passwordAffectsDesktop: value.passwordAffectsDesktop,
                  sshKeySet: value.sshKeySet ?? value.keySet, password: value.sshPassword,
                  connection: value.connectionInfo.map { .init(command: $0.command, user: $0.user, host: $0.host,
                                                              bastion: $0.bastion, scpUpload: $0.scpUpload, scpDownload: $0.scpDownload) })
    }
}
extension WorkspaceDomain {
    init(_ value: DomainInfo) {
        self.init(customDomain: value.customDomain ?? value.domain, port: value.port, includeWww: value.includeWww,
                  sslStatus: value.sslStatus, sslExpiry: value.sslExpiry, sslError: value.sslError)
    }
}
extension WorkspaceDomainCheck {
    init(_ value: DomainCheck) {
        self.init(verified: value.verified, errors: value.errors,
                  requiredRecords: value.requiredRecords.map { .init(cname: $0.cname.map { .init(host: $0.host, target: $0.target) },
                                                                     txt: $0.txt.map { .init(host: $0.host, value: $0.value) }) }, edgeIps: value.edgeIps)
    }
}
