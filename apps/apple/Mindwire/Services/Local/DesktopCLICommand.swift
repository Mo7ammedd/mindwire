#if targetEnvironment(macCatalyst)
import Darwin
import Foundation

/// Execs the installed CLI. This owns only a command's pipes and process group;
/// detached CLI services and their existing state outlive the window.
final class DesktopCLICommand: @unchecked Sendable {
    struct Event: Decodable, Sendable {
        let event: String?
        let message: String?
        let uri: String?
        let invitation: Invitation?
        let pairingId: String?
        let request: PhoneRequest?
        let fingerprint: String?
        let replacements: [Phone]?
        let devices: [Phone]?
        let enabled: Bool?

        struct Invitation: Decodable, Sendable { let pairingId: String; let expiresAt: String }
        struct PhoneRequest: Decodable, Sendable { let id: String; let name: String }
    }
    struct Phone: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let revoked: Bool
        let connected: Bool?
    }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true
        if pid > 0 { Darwin.kill(-pid, SIGTERM) }
        lock.unlock()
    }

    func events(_ arguments: [String]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.cancel() }
            }
            Task.detached(priority: .utility) { [self] in
                do { try execute(arguments, continuation: continuation); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
        }
    }

    private func execute(_ arguments: [String], continuation: AsyncThrowingStream<Event, Error>.Continuation) throws {
        guard let launcher = Bundle.main.url(forResource: "mindwire-cli", withExtension: "sh") else {
            throw BackendError.message("This Mindwire build is missing its CLI launcher.")
        }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptors[0]) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        // The CLI emits structured errors on stderr. Installer diagnostics can use
        // the same pipe; only JSON events are presented, and no pairing link is logged.
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Login-shell PATH discovers nvm/Homebrew too. All arguments are positional;
        // phone names, keys and IDs are never interpolated into shell source.
        let command = ["/bin/zsh", "-l", "-c", "exec /bin/sh \"$@\"", "mindwire-desktop", launcher.path] + arguments
        let argv = command.map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = LocalComputerRuntime.home.path
        environment["NO_COLOR"] = "1"
        let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv + envp { if let value { free(value) } } }
        var child: pid_t = 0
        lock.lock()
        if cancelled { lock.unlock(); Darwin.close(descriptors[1]); throw CancellationError() }
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in posix_spawn(&child, "/bin/zsh", &actions, &attributes, args.baseAddress!, env.baseAddress!) }
        }
        if result == 0 { pid = child }
        lock.unlock()
        Darwin.close(descriptors[1])
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        let decoder = JSONDecoder()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var failure: Error?
        do {
            while true {
                // A single read delivers available pipe bytes immediately.
                // FileHandle.read(upToCount:) can wait to fill the buffer and
                // hide the QR/approval event until the long-running CLI exits.
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptors[0], $0.baseAddress!, $0.count) }
                if count < 0 && errno == EINTR { continue }
                if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if count == 0 { break }
                pending.append(contentsOf: buffer.prefix(count))
                guard pending.count <= 262_144 else { throw BackendError.message("Mindwire returned an invalid command response.") }
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if let event = try? decoder.decode(Event.self, from: line) {
                        continuation.yield(event)
                        if event.event == "error" { failure = BackendError.message(event.message ?? "Mindwire couldn't complete the command.") }
                    }
                }
            }
        } catch {
            failure = error
            lock.lock()
            if pid > 0 { Darwin.kill(-pid, SIGTERM) }
            lock.unlock()
        }
        var status: Int32 = 0
        // Reap and clear the PID under the same lock as cancellation, so a late
        // cancellation cannot signal a process group after its PID is reused.
        while true {
            lock.lock()
            let waited = waitpid(child, &status, WNOHANG)
            let waitError = errno
            if waited == child || (waited < 0 && waitError != EINTR) { pid = 0 }
            lock.unlock()
            if waited == child { break }
            if waited < 0 && waitError != EINTR { throw POSIXError(POSIXErrorCode(rawValue: waitError) ?? .EIO) }
            usleep(25_000)
        }
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if let failure { throw failure }
        if status != 0 { throw BackendError.message("Mindwire couldn't complete the command. Try again, or run mindwire connect pair in Terminal.") }
    }
}
#endif
