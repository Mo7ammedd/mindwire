import Foundation
import OblienKit

struct CloudResourcePool: Decodable, Equatable {
    var cpus: Int?
    var memoryMb: Int?
    var diskMb: Int?
    private enum CodingKeys: String, CodingKey {
        case cpus
        case memoryMb = "memory_mb"
        case diskMb = "disk_size_mb"
    }
}

struct CloudResourceUsage: Decodable, Equatable {
    var count: Int
    var cpus: Int
    var memoryMb: Int
    var diskMb: Int
    private enum CodingKeys: String, CodingKey {
        case count, cpus
        case memoryMb = "memory_mb"
        case diskMb = "disk_size_mb"
    }
}

struct CloudWorkspaceQuota: Decodable, Equatable {
    var plan: String
    var planLabel: String
    var limits: CloudResourcePool
    var pool: CloudResourcePool
    var poolUsage: CloudResourceUsage
    var runningPool: CloudResourcePool
    var runningPoolUsage: CloudResourceUsage
    var maxWorkspaces: Int?
    var currentWorkspaces: Int
    var canCreate: Bool
    var reason: String?

    private enum CodingKeys: String, CodingKey {
        case plan, planLabel, limits, pool, maxWorkspaces, currentWorkspaces, canCreate, reason
        case poolUsage = "pool_usage"
        case runningPool = "running_pool"
        case runningPoolUsage = "running_pool_usage"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plan = try values.decodeIfPresent(String.self, forKey: .plan) ?? "Unknown"
        planLabel = try values.decodeIfPresent(String.self, forKey: .planLabel) ?? plan
        limits = try values.decodeIfPresent(CloudResourcePool.self, forKey: .limits) ?? .init(cpus: nil, memoryMb: nil, diskMb: nil)
        pool = try values.decodeIfPresent(CloudResourcePool.self, forKey: .pool) ?? .init(cpus: nil, memoryMb: nil, diskMb: nil)
        poolUsage = try values.decodeIfPresent(CloudResourceUsage.self, forKey: .poolUsage) ?? .zero
        runningPool = try values.decodeIfPresent(CloudResourcePool.self, forKey: .runningPool) ?? .init(cpus: nil, memoryMb: nil, diskMb: nil)
        runningPoolUsage = try values.decodeIfPresent(CloudResourceUsage.self, forKey: .runningPoolUsage) ?? .zero
        maxWorkspaces = try values.decodeIfPresent(Int.self, forKey: .maxWorkspaces)
        currentWorkspaces = try values.decodeIfPresent(Int.self, forKey: .currentWorkspaces) ?? 0
        canCreate = try values.decodeIfPresent(Bool.self, forKey: .canCreate) ?? true
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
    }

    init(_ value: OblienKit.Quota) {
        func resources(_ value: OblienKit.Resources?) -> CloudResourcePool {
            .init(cpus: value?.cpus, memoryMb: value?.memoryMb, diskMb: value?.diskSizeMb)
        }
        func usage(_ value: OblienKit.Quota.Usage?) -> CloudResourceUsage {
            .init(count: value?.count ?? 0, cpus: value?.cpus ?? 0,
                  memoryMb: value?.memoryMb ?? 0, diskMb: value?.diskSizeMb ?? 0)
        }
        plan = value.plan ?? "Unknown"
        planLabel = value.planLabel ?? plan
        limits = resources(value.limits)
        pool = resources(value.pool)
        poolUsage = usage(value.poolUsage)
        runningPool = resources(value.runningPool)
        runningPoolUsage = usage(value.runningPoolUsage)
        maxWorkspaces = value.maxWorkspaces ?? value.maxSandboxes
        currentWorkspaces = value.currentWorkspaces ?? value.currentSandboxes ?? 0
        canCreate = value.canCreate ?? true
        reason = value.reason
    }

    func denial(for spec: WorkspaceSpec) -> String? {
        if !canCreate { return reason ?? "Your plan's workspace limit has been reached." }
        if let maxWorkspaces, currentWorkspaces >= maxWorkspaces {
            return "Your \(planLabel) plan allows \(maxWorkspaces) workspaces."
        }
        if exceeds(spec, cap: limits, used: nil) { return "This workspace exceeds your \(planLabel) per-workspace limit." }
        if exceeds(spec, cap: pool, used: poolUsage) { return "Your owned resource pool does not have enough capacity." }
        if exceeds(spec, cap: runningPool, used: runningPoolUsage) { return "Your running resource pool does not have enough capacity." }
        return nil
    }

    private func exceeds(_ spec: WorkspaceSpec, cap: CloudResourcePool, used: CloudResourceUsage?) -> Bool {
        func over(_ requested: Int, _ limit: Int?, _ consumed: Int) -> Bool {
            limit.map { requested > max(0, $0 - consumed) } ?? false
        }
        return over(spec.cpus, cap.cpus, used?.cpus ?? 0)
            || over(spec.memoryMb, cap.memoryMb, used?.memoryMb ?? 0)
            || over(spec.diskMb, cap.diskMb, used?.diskMb ?? 0)
    }
}

private extension CloudResourceUsage {
    static let zero = CloudResourceUsage(count: 0, cpus: 0, memoryMb: 0, diskMb: 0)
}

struct CloudCreditEstimate: Decodable, Equatable {
    struct Range: Decodable, Equatable { var min: Double; var avg: Double; var max: Double }
    var estimate: Range
    var period: String
}

struct CloudDailyCreditUsage: Decodable, Equatable {
    var date: String
    var usage: Double
    var purchases: Double
}

private struct CloudCreditUsageEnvelope: Decodable {
    var data: [CloudDailyCreditUsage]?
}

struct CloudPlanOption: Decodable, Equatable {
    var family: String
    var name: String
}

private struct CloudPlansEnvelope: Decodable {
    var plans: [CloudPlanOption]?
}

struct CloudAccountOverview: Equatable {
    var balance: Double?
    var quota: CloudWorkspaceQuota?
    var estimate: CloudCreditEstimate?
    var dailyUsage: [CloudDailyCreditUsage] = []
    var plans: [CloudPlanOption] = []

    var creditsUsedLast30Days: Double { dailyUsage.reduce(0) { $0 + $1.usage } }

    var creationDenial: String? {
        if let balance, balance <= 0 { return "Your credit balance is depleted." }
        return nil
    }

    var canUpgradePlan: Bool {
        guard let current = quota?.plan,
              let index = plans.firstIndex(where: { $0.family == current }) else { return false }
        return index < plans.index(before: plans.endIndex)
    }

    var nextPlanName: String? {
        guard canUpgradePlan, let current = quota?.plan,
              let index = plans.firstIndex(where: { $0.family == current }) else { return nil }
        return plans[plans.index(after: index)].name
    }
}

enum OblienBilling {
    private struct BalanceEnvelope: Decodable { var balance: Double?; var available: Double? }

    static func overview(for spec: WorkspaceSpec? = nil) async -> CloudAccountOverview {
        async let balanceResult = try? OblienAPI.shared.get("/credits/balance", as: BalanceEnvelope.self)
        async let quotaResult = try? OblienCloud.client.workspaces.getQuota()
        async let usageResult = try? OblienAPI.shared.get(
            "/credits/usage-stats?days=30", as: CloudCreditUsageEnvelope.self
        )
        async let plansResult = try? OblienAPI.shared.get("/credits/plans", as: CloudPlansEnvelope.self)
        let estimateResult: CloudCreditEstimate?
        if let spec {
            let value = try? await OblienCloud.client.workspaces.estimate(cpu: spec.cpus, ramMb: spec.memoryMb, diskMb: spec.diskMb)
            estimateResult = value.map { .init(estimate: .init(min: $0.estimate.min, avg: $0.estimate.avg, max: $0.estimate.max), period: $0.period) }
        } else {
            estimateResult = nil
        }
        let (balance, quota, usage, plans) = await (balanceResult, quotaResult, usageResult, plansResult)
        return CloudAccountOverview(balance: balance?.available ?? balance?.balance,
                                    quota: quota.map(CloudWorkspaceQuota.init),
                                    estimate: estimateResult,
                                    dailyUsage: usage?.data ?? [],
                                    plans: plans?.plans ?? [])
    }

    static func creationMessage(for error: Error) -> String {
        let description = error.localizedDescription
        let sdkCode = (error as? OblienError)?.code
        // Some control-plane responses currently put the machine reason in `error`
        // instead of `code`; retain exact UX until the SDK normalizes both shapes.
        let knownCodes = ["INSUFFICIENT_CREDITS", "RUNNING_POOL_REACHED", "POOL_LIMIT_REACHED",
                          "SANDBOX_LIMIT_REACHED", "VM_UNAVAILABLE"]
        let code = sdkCode ?? knownCodes.first(where: description.contains)
        switch code {
        case "INSUFFICIENT_CREDITS": return "Your credit balance is depleted. Add credits or upgrade your plan."
        case "RUNNING_POOL_REACHED": return "Your running resource limit is full. Stop another workspace or upgrade your plan."
        case "POOL_LIMIT_REACHED": return "Your owned resource pool is full. Delete a workspace or upgrade your plan."
        case "SANDBOX_LIMIT_REACHED": return "Your plan's workspace limit has been reached."
        case "VM_UNAVAILABLE": return "That workspace size is temporarily unavailable. Try another size or try again later."
        default: return description
        }
    }
}
