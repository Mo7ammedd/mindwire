import Foundation
import OblienKit

/// Private stdin over the SDK's exec stream. Passwords never appear in arguments,
/// shell interpolation, saved task logs or app diagnostics.
struct CloudDesktopNativeInput: Sendable {
    let runtime: RuntimeClient
    init(runtime: RuntimeClient) { self.runtime = runtime }
    init(baseURL: URL, token: String, session: URLSession) {
        runtime = RuntimeClient(token: token, baseURL: baseURL, session: session)
    }

    func run(target: String, command: [String], input: Data) async throws -> Data {
        guard input.count <= 32768 else { throw failure() }
        do {
            let selected = try runtime.forTarget(target)
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await runStream(runtime: selected, command: command, input: input) }
                group.addTask { try await Task.sleep(for: .seconds(65)); throw failure() }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw failure() }
                return result
            }
        } catch {
            try Task.checkCancellation()
            throw failure()
        }
    }

    private func runStream(runtime: RuntimeClient, command: [String], input: Data) async throws -> Data {
        let encoded = input.base64EncodedData()
        let marker = "MINDWIRE_NATIVE_INPUT_READY"
        let script = "stty -echo -icanon 2>/dev/null || true\nprintf '\(marker)\\n'\n/usr/bin/head -c \(encoded.count) | /usr/bin/base64 -D | \"$@\""
        var taskID: String?
        var sent = false
        var stdout = Data()
        var total = 0
        for try await event in runtime.exec.stream(["/bin/sh", "-c", script, "mindwire-input"] + command,
            timeoutSeconds: 55, ttlSeconds: 70, keepLogs: false) {
            try Task.checkCancellation()
            total += event.raw.utf8.count
            guard total <= 262144 else { throw failure() }
            switch event.kind {
            case .taskId:
                guard taskID == nil, let id = event.taskId,
                      id.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw failure() }
                taskID = id
            case .stdout:
                guard let value = event.data else { throw failure() }
                stdout.append(value)
                guard stdout.count <= 65536 else { throw failure() }
            case .exit:
                guard sent, event.exitCode == 0 else { throw failure() }
                // Task IDs are reusable. Server TTL owns cleanup; never send a delayed DELETE.
                return stdout
            default: break
            }
            if !sent, let taskID, let range = stdout.range(of: Data(marker.utf8)) {
                sent = true
                stdout.removeSubrange(range)
                try await runtime.exec.input(taskID, encoded)
            }
        }
        throw failure()
    }

    private func failure() -> DesktopProblem {
        .init(code: "login_unavailable", message: "Automatic sign-in could not finish. You can still sign in on the Mac.")
    }
}
