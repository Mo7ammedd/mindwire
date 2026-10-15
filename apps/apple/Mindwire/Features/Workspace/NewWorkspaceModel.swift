import SwiftUI
import Observation
import OblienKit

/// Drives the New Workspace wizard: draft fields, runtime selection, and the staged
/// provisioning overlay backed by a `RuntimeProvisioner`. Mirrors `NewAgentModel`,
/// minus the agent-type and project fields (a workspace is runtime + power only).
@MainActor
@Observable
final class NewWorkspaceModel {
    // Draft fields
    var name: String = ""

    /// Runtime selection. `nil` serverId means Oblien Cloud; otherwise a saved server's id.
    var selectedServerId: String? {
        didSet {
            if selectedServerId != oldValue { sandbox = nil; serviceVersion = nil; useSandbox = false }
        }
    }
    var useSandbox = false
    @ObservationIgnored private var sandbox: ServerSandbox?
    @ObservationIgnored private var serviceVersion: String?
    /// Cloud resources are explicitly selected; Oblien quota decides whether they fit.
    var customCPUs = 2
    var customMemoryGb = 4
    var customDiskGb = 20

    /// Cloud-only base image (listed live from Oblien; defaults to a node image).
    var images: [WorkspaceImage] = []
    var selectedImageID: String? {
        didSet { if selectedImageID != oldValue { applyImageDefaults() } }
    }
    var selectedImage: WorkspaceImage? { images.first { $0.id == selectedImageID } }
    let storage = WorkspaceCreationStorage()
    var loadingImages = false
    var imagesError: String?
    var cloudAuthRequired = false
    var accountOverview: CloudAccountOverview?
    var loadingAccount = false

    // Provisioning state
    var isProvisioning = false
    var stage: ProvisionStageKey = .creating
    var errorMessage: String?
    @ObservationIgnored private var submission: (signature: Data, key: String)?

    var isCloud: Bool { selectedServerId == nil }

    var customMaximumCPUs: Int { WorkspaceLimits.cpus.max }
    var customMaximumMemoryGb: Int { WorkspaceLimits.memoryMb.max / 1024 }
    var customMaximumDiskGb: Int { WorkspaceLimits.diskMb.max / 1024 }
    var minimumCPUs: Int { selectedImage?.minimumCPUs ?? 1 }
    var minimumMemoryGb: Int { max(1, Int(ceil(Double(selectedImage?.minimumMemoryMb ?? 1024) / 1024))) }
    var minimumDiskGb: Int { max(1, Int(ceil(Double(selectedImage?.minimumDiskMb ?? 1024) / 1024))) }

    var creationDenial: String? {
        storage.validation(image: selectedImage) ?? accountOverview?.creationDenial ?? accountOverview?.quota?.denial(for: spec)
    }

    func loadAccountOverview() async {
        guard isCloud else { accountOverview = nil; return }
        let requested = spec
        loadingAccount = true
        let result = await OblienBilling.overview(for: requested)
        guard !Task.isCancelled, requested == spec else { return }
        accountOverview = result
        loadingAccount = false
    }

    /// The spec to persist with the workspace: cloud → selected preset; server → default.
    var spec: WorkspaceSpec {
        guard isCloud || useSandbox else { return WorkspaceSpecs.selfHostedDefault }
        return WorkspaceSpec(cpus: customCPUs, memoryMb: customMemoryGb * 1024,
                             diskMb: isCloud ? (storage.root?.sizeMb ?? customDiskGb * 1024) : 0, persistent: true)
    }

    /// Load the cloud image catalog and auto-select a node image (or the first available).
    func loadImages(force: Bool = false) async {
        guard (force || images.isEmpty), !loadingImages else { return }
        loadingImages = true
        imagesError = nil
        guard await OblienAuth.shared.ensure() else {
            cloudAuthRequired = true
            loadingImages = false
            return
        }
        cloudAuthRequired = false
        do {
            images = try await CloudImages.list(force: force)
            if selectedImageID == nil {
                selectedImageID = storage.root?.rootImage.flatMap { CloudImages.match($0, in: images) }?.id
                    ?? images.first { $0.id.localizedCaseInsensitiveContains("node") }?.id
                    ?? images.first?.id
            }
        } catch {
            imagesError = error.localizedDescription
        }
        loadingImages = false
    }

    func selectRoot(_ disk: WorkspaceManagedDisk?) {
        storage.root = disk
        if let disk {
            storage.namespace = disk.namespace ?? ""
            if let reference = disk.rootImage, let image = CloudImages.match(reference, in: images) { selectedImageID = image.id }
        }
    }

    private func applyImageDefaults() {
        guard let image = selectedImage else { return }
        customCPUs = max(minimumCPUs, image.vmDefaults?.cpus ?? customCPUs)
        customMemoryGb = max(minimumMemoryGb, image.vmDefaults?.memoryMb.map { Int(ceil(Double($0) / 1024)) } ?? customMemoryGb)
        customDiskGb = max(minimumDiskGb, image.vmDefaults?.diskSizeMb.map { Int(ceil(Double($0) / 1024)) } ?? customDiskGb)
    }

    /// Retry exactly the same draft with exactly the same key, including after a lost response.
    func cloudOptions() throws -> CloudProvisioningOptions {
        guard let image = selectedImage else { throw WorkspaceControlError(message: "Choose a workspace image.") }
        if let message = storage.validation(image: image) { throw WorkspaceControlError(message: message) }
        var options = CloudProvisioningOptions(image: image.image, preset: image.preset, namespace: storage.namespace.nonBlank,
            defaults: image.vmDefaults, rootDiskId: storage.root?.id, disks: storage.attachments.map(\.sdkValue), idempotencyKey: "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let signature = try encoder.encode(options.request(name: name.trimmingCharacters(in: .whitespacesAndNewlines), spec: spec))
        if submission?.signature != signature { submission = (signature, UUID().uuidString) }
        options.idempotencyKey = submission!.key
        return options
    }

    /// Resolve the current selection to a provisioning target. `nil` if a server was
    /// selected but no longer exists.
    private func choice(servers: [Connection]) -> ProvisionChoice? {
        guard let serverId = selectedServerId else { return .cloud }
        guard let server = servers.first(where: { $0.id == serverId }) else { return nil }
        return .server(server)
    }

    /// Runs the staged provisioner. Returns the resolved runtime, or `nil` after
    /// recording an error message (the caller keeps the wizard open for retry).
    func provision(servers: [Connection]) async -> AgentRuntime? {
        guard !isProvisioning else { return nil }
        guard let choice = choice(servers: servers) else {
            errorMessage = "This server is no longer saved. Choose another connection or add it again."
            return nil
        }
        errorMessage = nil
        isProvisioning = true
        stage = .creating
        do {
            if !isCloud, useSandbox, sandbox == nil {
                let version = try await ReleaseCatalog.shared.load(maxAge: 300).version
                guard DaemonRelease.satisfies(version, target: ServerSandbox.minimumServiceVersion) else {
                    throw BackendError.message("Docker workspaces need Mindwire service \(ServerSandbox.minimumServiceVersion) or later. Try again when that release is available.")
                }
                let imageVersion = try await RuntimeImageRelease.version(for: version)
                serviceVersion = version
                sandbox = ServerSandbox(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), version: imageVersion)
            }
            let provisioner = BackendFactory.provisioner(
                for: choice,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                cloud: isCloud ? try cloudOptions() : nil,
                sandbox: !isCloud && useSandbox ? sandbox : nil, serviceVersion: serviceVersion
            )
            let runtime = try await provisioner.provision(spec) { [weak self] stage in
                self?.stage = stage
            }
            return runtime
        } catch {
            errorMessage = OblienBilling.creationMessage(for: error)
            isProvisioning = false
            return nil
        }
    }
}
