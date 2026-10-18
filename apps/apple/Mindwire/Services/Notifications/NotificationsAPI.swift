import Foundation

/// Mindwire owns device registration and send-only credentials. Real FCM tokens
/// are write-only; runtime send tokens never grant device-management access.
protocol PushDeviceRegistry {
    func registerDevice(deviceId: String, fcmToken: String, platform: String,
                        deviceInfo: [String: String]?) async throws -> PushDevice
    func status(deviceId: String) async throws -> DeviceStatus
    func removeDevice(id: Int) async throws
}

struct NotificationsAPI: PushDeviceRegistry {
    private let api: MindwireServicesAPI

    init(api: MindwireServicesAPI = .shared) { self.api = api }

    /// Upsert (register/refresh) this device's FCM token, keyed on `(user, device_id)`. Re-activates
    /// a previously revoked device. Call on first launch after permission, and on FCM token refresh.
    @discardableResult
    func registerDevice(deviceId: String, fcmToken: String, platform: String = "ios",
                        deviceInfo: [String: String]? = nil) async throws -> PushDevice {
        var body: [String: Any] = ["device_id": deviceId, "fcm_token": fcmToken, "platform": platform]
        if let deviceInfo { body["device_info"] = deviceInfo }
        let data = try await api.send("POST", "/api/notifications/devices",
                                      body: JSONSerialization.data(withJSONObject: body)) ?? Data()
        return try JSONDecoder().decode(RegisterResponse.self, from: data).device
    }

    /// Cheap single-device check — use on launch/foreground before trusting push.
    func status(deviceId: String) async throws -> DeviceStatus {
        let q = deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
        let data = try await api.send("GET", "/api/notifications/devices/status?device_id=\(q)") ?? Data()
        return try JSONDecoder().decode(DeviceStatus.self, from: data)
    }

    /// All of the user's registered devices (most-recently-seen first) — for a "manage devices" screen.
    func listDevices() async throws -> [PushDevice] {
        let data = try await api.send("GET", "/api/notifications/devices") ?? Data()
        return try JSONDecoder().decode(DeviceListResponse.self, from: data).devices
    }

    /// Remove a device by its numeric row id (from register/list/status), e.g. on logout.
    func removeDevice(id: Int) async throws {
        _ = try await api.send("DELETE", "/api/notifications/devices/\(id)")
    }

    func listSendTokens(workspaceID: String?) async throws -> [NotificationSendToken] {
        let suffix = workspaceID.map { "?workspace_id=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) } ?? ""
        let data = try await api.send("GET", "/api/notifications/tokens" + suffix) ?? Data()
        struct Response: Decodable { let tokens: [NotificationSendToken] }
        return try JSONDecoder().decode(Response.self, from: data).tokens
    }

    func createSendToken(workspaceID: String?, tag: String, name: String = "Mindwire", metadata: [String: String], expiresInDays: Int? = nil) async throws -> NotificationSendToken {
        var body: [String: Any] = ["tag": tag, "name": name, "metadata": metadata]
        if let workspaceID { body["workspace_id"] = workspaceID }
        if let expiresInDays { body["expires_in_days"] = expiresInDays }
        let data = try await api.send("POST", "/api/notifications/tokens", body: JSONSerialization.data(withJSONObject: body)) ?? Data()
        struct Response: Decodable { let token: NotificationSendToken }
        return try JSONDecoder().decode(Response.self, from: data).token
    }

    func deleteSendToken(id: Int) async throws {
        _ = try await api.send("DELETE", "/api/notifications/tokens/\(id)")
    }
}

// MARK: - DTOs

struct PushDevice: Decodable, Identifiable, Hashable {
    let id: Int
    let deviceId: String
    let platform: String
    let status: String     // "active" | "revoked"
    enum CodingKeys: String, CodingKey {
        case id, platform, status
        case deviceId = "device_id"
    }
    var isActive: Bool { status == "active" }
}

struct DeviceStatus: Decodable {
    let registered: Bool
    let status: String?    // "active" | "revoked" — present only when registered
    let id: Int?
    var isActive: Bool { registered && status == "active" }
}

private struct RegisterResponse: Decodable { let device: PushDevice }
private struct DeviceListResponse: Decodable { let devices: [PushDevice] }
