#if targetEnvironment(macCatalyst)
import Foundation
import Observation
import CoreImage.CIFilterBuiltins
import UIKit

/// Transient presentation of CLI output only. No saved devices, keys, provider
/// settings or startup preferences are stored by the app.
@MainActor @Observable
final class DesktopPhoneConnection {
    static let shared = DesktopPhoneConnection()
    enum Phase { case preparing, scanning, approval, saving, connected, failed }
    struct Approval {
        let pairingID: String
        let requestID: String
        let name: String
        let fingerprint: String
        let replacements: [DesktopCLICommand.Phone]
    }
    private(set) var phase: Phase = .preparing
    private(set) var status = "Preparing Mindwire…"
    private(set) var link: String?
    private(set) var code: UIImage?
    private(set) var expiresAt: Date?
    private(set) var approval: Approval?
    private(set) var phones: [DesktopCLICommand.Phone] = []
    private(set) var startupEnabled = false
    private(set) var startupKnown = false
    private(set) var changing = false
    private(set) var refreshing = false
    private(set) var actionError: String?
    private var task: Task<Void, Never>?
    private var command: DesktopCLICommand?
    private var presentations = 0
    private var prepared = false
    private var generation = UUID()
    private static let imageContext = CIContext()

    func attach() {
        presentations += 1
        if presentations == 1 { start() }
    }

    func detach() {
        presentations = max(0, presentations - 1)
        if presentations == 0 {
            generation = UUID(); task?.cancel(); command?.cancel()
            command = nil; link = nil; code = nil; approval = nil
        }
    }

    func start() {
        let previous = task
        task?.cancel(); command?.cancel()
        let token = UUID(); generation = token
        phase = .preparing; status = "Preparing Mindwire…"
        link = nil; code = nil; expiresAt = nil; approval = nil; actionError = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { task = nil; command = nil } }
            do {
                // An old foreground command must exit before another invitation
                // starts. The detached computer service is never stopped.
                await previous?.value
                try Task.checkCancellation()
                if !prepared {
                    let setup = DesktopCLICommand(); command = setup
                    try await consume(setup, arguments: ["prepare"], token: token)
                    prepared = true
                }
                await refreshPhones()
                try Task.checkCancellation()
                let pairing = DesktopCLICommand(); command = pairing
                try await consume(pairing, arguments: ["pair"], token: token)
                guard generation == token else { return }
                await refreshPhones()
                if phase == .preparing {
                    throw BackendError.message("Mindwire didn't return a connection code. Try again.")
                }
            } catch {
                if generation == token, !Task.isCancelled, !error.isRequestCancellation {
                    phase = .failed; status = error.localizedDescription
                    link = nil; code = nil; approval = nil
                }
            }
        }
    }

    private func consume(_ process: DesktopCLICommand, arguments: [String], token: UUID) async throws {
        try await withTaskCancellationHandler {
            for try await event in process.events(arguments) {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                receive(event)
            }
        } onCancel: { process.cancel() }
    }

    private func receive(_ event: DesktopCLICommand.Event) {
        switch event.event {
        case "starting": status = "Preparing your connection…"
        case "progress": if let message = event.message { status = message }
        case "invitation":
            guard let uri = event.uri, let invitation = event.invitation else { return }
            link = uri; code = Self.qrCode(uri); expiresAt = Self.date(invitation.expiresAt)
            phase = .scanning; status = "Scan in Mindwire on your phone."
        case "approval_required":
            guard let request = event.request, let pairingID = event.pairingId else { return }
            approval = Approval(pairingID: pairingID, requestID: request.id, name: request.name,
                                fingerprint: event.fingerprint ?? "", replacements: event.replacements ?? [])
            code = nil; link = nil; phase = .approval
            status = "Allow \(request.name) to connect?"
        case "authorized": phase = .saving; approval = nil; code = nil; link = nil; status = "Saving the connection on your phone…"
        case "paired", "connected":
            phase = .connected; approval = nil; code = nil; link = nil
            status = "Your phone is connected."
        case "waiting_for_phone":
            phase = .scanning; status = "Open Mindwire on your saved phone, or show a new code."
        case "rejected": phase = .failed; approval = nil; status = "The phone wasn't connected."
        case "startup":
            if let enabled = event.enabled { startupEnabled = enabled; startupKnown = true }
        case "saved_devices", "devices":
            if let devices = event.devices { phones = devices.filter { !$0.revoked } }
        default: break
        }
    }

    func decide(allow: Bool, replace: Bool = false) {
        guard let approval, !changing else { return }
        var arguments = ["cli", allow ? "approve" : "reject"]
        if replace { arguments += approval.replacements.flatMap { ["--replace-device", $0.id] } }
        arguments += ["--", approval.pairingID, approval.requestID]
        action(arguments) { }
    }

    func setStartup(_ enabled: Bool) {
        action(["cli", "startup", enabled ? "enable" : "disable"]) { [self] in startupEnabled = enabled }
    }

    func revoke(_ phone: DesktopCLICommand.Phone) {
        action(["cli", "revoke", "--", phone.id]) { [self] in
            Task { await refreshPhones() }
        }
    }

    private func action(_ arguments: [String], completion: @escaping @MainActor () -> Void) {
        guard !changing else { return }
        changing = true; actionError = nil
        Task {
            defer { changing = false }
            do {
                let operation = DesktopCLICommand()
                for try await event in operation.events(arguments) { receive(event) }
                completion()
            } catch { actionError = error.localizedDescription }
        }
    }

    func refreshPhones() async {
        guard prepared, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let operation = DesktopCLICommand()
            for try await event in operation.events(["cli", "devices"]) {
                if let devices = event.devices { phones = devices.filter { !$0.revoked } }
            }
        } catch { /* Pairing reports actionable failures; an optional list refresh keeps its last snapshot. */ }
    }

    private static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = imageContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
#endif
