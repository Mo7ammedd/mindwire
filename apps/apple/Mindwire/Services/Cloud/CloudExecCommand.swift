import Foundation

/// The cloud runtime can report exit 124 for an already-completed command. Read the
/// actual shell exit status from a per-request receipt without retrying the command.
/// A missing or truncated receipt is never accepted as a successful execution.
struct CloudExecCommand {
    let arguments: [String]
    let marker = "<<MINDWIRE_EXIT_" + UUID().uuidString + ":"

    init(_ arguments: [String]) throws {
        guard arguments.first?.isEmpty == false, !arguments.contains(where: { $0.contains("\0") }) else {
            throw BackendError.message(t("workspace.exec.invalidCommand"))
        }
        self.arguments = arguments
    }

    var wrappedArguments: [String] {
        // Positional arguments preserve paths, quotes and multiline scripts without
        // interpreting them again. The subshell also handles an argv of `exit`/`exec`.
        ["/bin/sh", "-c", """
        if ( "$@" ); then mindwire_exec_status=0; else mindwire_exec_status=$?; fi
        printf '\(marker)%s>>' "$mindwire_exec_status"
        exit "$mindwire_exec_status"
        """, "mindwire-exec"] + arguments
    }

    func decode(_ result: ExecResult) throws -> ExecResult {
        guard result.truncated != true,
              let receipt = result.stdout.range(of: marker, options: .backwards) else {
            throw BackendError.message(t("workspace.exec.unconfirmed"))
        }
        let value = result.stdout[receipt.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix(">>"),
              let status = Int(value.dropLast(2)), (0...255).contains(status),
              value == "\(status)>>" else {
            throw BackendError.message(t("workspace.exec.unconfirmed"))
        }
        return ExecResult(exitCode: status, stdout: String(result.stdout[..<receipt.lowerBound]),
                          stderr: result.stderr, truncated: false)
    }
}
