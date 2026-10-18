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
    /// Cloud resources come from the Mindwire monthly computer catalog.
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
    var cloudPlans: [CloudComputerPlan] = []
    var selectedPlanId = "essential"
    var pendingPurchase: CloudComputer?
    var cloudCatalogError: String?
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

    var selectedPlan: CloudComputerPlan? { cloudPlans.first { $0.id == selectedPlanId } }
    var creationDenial: String? {
        guard isCloud else { return nil }
        if let cloudCatalogError { return cloudCatalogError }
        guard let plan = selectedPlan else { return "Choose a monthly Cloud Computer plan." }
        guard plan.vcpus >= minimumCPUs, plan.memoryMb >= minimumMemoryGb * 1024, plan.diskGb >= minimumDiskGb else {
            return "Choose a larger computer for this image."
        }
        return nil
    }

    func loadAccountOverview() async {
        guard isCloud else { return }
        loadingAccount = true
        defer { loadingAccount = false }
        do {
            let catalog = try await CloudComputers.catalog()
            cloudPlans = catalog.plans
            cloudCatalogError = catalog.available ? nil : "Cloud Computer purchases are not enabled yet. Your own computers are still available."
        } catch { cloudCatalogError = error.localizedDescription }
    }

    /// The spec to persist with the workspace: cloud → selected preset; server → default.
    var spec: WorkspaceSpec {
        if isCloud, let plan = selectedPlan { return WorkspaceSpec(cpus: plan.vcpus, memoryMb: plan.memoryMb, diskMb: plan.diskGb * 1024, persistent: true) }
        guard isCloud || useSandbox else { return WorkspaceSpecs.selfHostedDefault }
        return WorkspaceSpec(cpus: customCPUs, memoryMb: customMemoryGb * 1024,
                             diskMb: isCloud ? (storage.root?.sizeMb ?? customDiskGb * 1024) : 0, persistent: true)
    }

    /// Load the cloud image catalog and auto-select a node image (or the first available).
    func loadImages(force: Bool = false) async {
        guard (force || images.isEmpty), !loadingImages else { return }
        loadingImages = true
        imagesError = nil
        guard await MindwireAuth.shared.ensure() else {
            cloudAuthRequired = true
            loadingImages = false
            return
        }
        cloudAuthRequired = false
        do {
            images = try await MindwireAPI.shared.get("/workspace/images?monthly=true", as: OblienKit.ImageList.self).images.compactMap(WorkspaceImage.init(catalogImage:))
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
        var options = CloudProvisioningOptions(planId: selectedPlanId, catalogImageId: image.id, image: image.image, preset: image.preset, namespace: storage.namespace.nonBlank,
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
        } catch let checkout as CloudCheckoutRequired {
            pendingPurchase = checkout.computer
            isProvisioning = false
            return nil
        } catch {
            errorMessage = error.localizedDescription
            isProvisioning = false
            return nil
        }
    }
}
