import Foundation

/// Mobile push **device registry** — `api.oblien.com/notifications/devices*`, authenticated with
/// the Oblien session JWT via the shared `OblienAPI` actor (token mint + Keychain + 401-refresh
/// reused). Only the device half of `/notifications` is the app's concern; workspace send tokens
/// are server-side and out of scope here. The real `fcm_token` is write-only — never returned.
protocol PushDeviceRegistry {
    func registerDevice(deviceId: String, fcmToken: String, platform: String,
                        deviceInfo: [String: String]?) async throws -> PushDevice
    func status(deviceId: String) async throws -> DeviceStatus
    func removeDevice(id: Int) async throws
}

struct NotificationsAPI: PushDeviceRegistry {
    private let api: OblienAPI

    init(api: OblienAPI = .shared) { self.api = api }

    /// Upsert (register/refresh) this device's FCM token, keyed on `(user, device_id)`. Re-activates
    /// a previously revoked device. Call on first launch after permission, and on FCM token refresh.
    @discardableResult
    func registerDevice(deviceId: String, fcmToken: String, platform: String = "ios",
                        deviceInfo: [String: String]? = nil) async throws -> PushDevice {
        var body: [String: Any] = ["device_id": deviceId, "fcm_token": fcmToken, "platform": platform]
        if let deviceInfo { body["device_info"] = deviceInfo }
        let data = try await api.send("POST", "/notifications/devices",
                                      body: JSONSerialization.data(withJSONObject: body)) ?? Data()
        return try JSONDecoder().decode(RegisterResponse.self, from: data).device
    }

    /// Cheap single-device check — use on launch/foreground before trusting push.
    func status(deviceId: String) async throws -> DeviceStatus {
        let q = deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
        let data = try await api.send("GET", "/notifications/devices/status?device_id=\(q)") ?? Data()
        return try JSONDecoder().decode(DeviceStatus.self, from: data)
    }

    /// All of the user's registered devices (most-recently-seen first) — for a "manage devices" screen.
    func listDevices() async throws -> [PushDevice] {
        let data = try await api.send("GET", "/notifications/devices") ?? Data()
        return try JSONDecoder().decode(DeviceListResponse.self, from: data).devices
    }

    /// Remove a device by its numeric row id (from register/list/status), e.g. on logout.
    func removeDevice(id: Int) async throws {
        _ = try await api.send("DELETE", "/notifications/devices/\(id)")
    }

    // Workspace send tokens moved to the SDK — `OblienCloud.client.notifications.*`
    // (`createSendToken`/`listSendTokens`/`revoke`/`delete`). FCM device registration stays here.
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
