import Foundation

struct CloudComputerPlan: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let monthlyCents: Int
    let vcpus: Int
    let memoryMb: Int
    let diskGb: Int
    var monthlyPrice: String { (Double(monthlyCents) / 100).formatted(.currency(code: "USD")) + "/month" }
}

struct CloudComputer: Decodable, Identifiable, Sendable {
    struct Checkout: Decodable, Sendable { let url: URL; let id: String }
    struct Subscription: Decodable, Sendable { let status: String; let paidThrough: String?; let cancelAtPeriodEnd: Bool }
    let id: String
    let name: String
    let state: String
    let plan: CloudComputerPlan
    let workspaceId: String?
    let checkout: Checkout?
    let subscription: Subscription?
}

struct CloudCheckoutRequired: Error { let computer: CloudComputer }

enum CloudComputers {
    struct Catalog: Decodable { let available: Bool; let plans: [CloudComputerPlan] }
    private struct Envelope: Decodable { let computer: CloudComputer }
    static func catalog() async throws -> Catalog {
        try await decode(Catalog.self, path: "/api/cloud/catalog")
    }
    static func list() async throws -> [CloudComputer] {
        struct Result: Decodable { let computers: [CloudComputer] }
        return try await decode(Result.self, path: "/api/cloud/computers").computers
    }
    static func purchase(name: String, planId: String, imageId: String, key: String) async throws -> CloudComputer {
        let input = try JSONSerialization.data(withJSONObject: ["name": name, "planId": planId, "imageId": imageId, "idempotencyKey": key])
        let draft = try await decode(Envelope.self, method: "POST", path: "/api/cloud/computers", body: input).computer
        return try await checkout(draft.id)
    }
    static func checkout(_ id: String) async throws -> CloudComputer {
        try await decode(Envelope.self, method: "POST", path: "/api/cloud/computers/\(id)/checkout").computer
    }
    static func reconcile(_ id: String) async throws -> CloudComputer {
        try await decode(Envelope.self, method: "POST", path: "/api/cloud/computers/\(id)/reconcile").computer
    }
    static func billingPortal(_ id: String) async throws -> URL {
        struct Portal: Decodable { let url: URL }
        let url = try await decode(Portal.self, method: "POST", path: "/api/cloud/computers/\(id)/billing-portal").url
        guard url.scheme == "https", url.host == "billing.stripe.com", url.user == nil, url.password == nil else { throw APIError.badURL(url.absoluteString) }
        return url
    }
    private static func decode<T: Decodable>(_ type: T.Type, method: String = "GET", path: String, body: Data? = nil) async throws -> T {
        guard let data = try await MindwireAPI.shared.accountRequest(method, path, body: body) else { throw APIError.transport(path) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
