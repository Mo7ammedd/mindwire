import Foundation

/// The **executor** seam of a workspace — distinct from the **transport** (`WorkspaceService.exec`,
/// which just ships an argv to the remote machine). A `Shell` owns the platform-specific encoding:
/// how a script body is wrapped into an argv, how a value is quoted, and the small toolbox the file
/// + git layers compose (`ls`/`cat`/`mv`/`rm`/`base64`/…). The git porcelain and `git clone`
/// commands themselves are platform-agnostic — only this thin wrapper around them is POSIX.
///
/// Every workspace is Linux today, so `PosixShell` is the only conformer. A future Windows/macOS
/// workspace adds one `Shell` conformer (overriding whichever toolbox members differ) and promotes
/// `WorkspaceService.shell` to a real per-adapter requirement — nothing in the git/file/clone layers
/// changes, because they speak this vocabulary, not raw `bash`.
protocol Shell: Sendable {
    /// Wrap a shell script body into the argv that `WorkspaceService.exec` runs.
    func command(_ script: String) -> [String]
    /// Quote a single value for safe interpolation into a script (paths, commit messages, …).
    func quote(_ value: String) -> String

    // MARK: Toolbox — composable script fragments built on `quote`. Defaults below are POSIX.

    /// List a directory, one entry per line, dirs suffixed with `/` (the `ls -1Ap` shape both
    /// workspace adapters parse).
    func listDir(_ path: String) -> String
    /// Recursive filename search, type-tagged (`%y\t%p`), capped.
    func find(_ query: String, in dir: String) -> String
    /// Read a text file to stdout.
    func readFile(_ path: String) -> String
    /// Write `base64`-encoded bytes to `path`, creating parent dirs.
    func writeFile(_ path: String, base64: String) -> String
    /// Read up to `capBytes` of a file and base64-encode it (binary-safe transport).
    func readFileBase64(_ path: String, capBytes: Int) -> String
    /// Cap piped stdin to `capBytes` and base64-encode it (e.g. `git show … | …`).
    func base64Capture(capBytes: Int) -> String
    /// Create a directory (and parents).
    func makeDir(_ path: String) -> String
    /// Move / rename.
    func move(from: String, to: String) -> String
    /// Recursive copy.
    func copy(from: String, to: String) -> String
    /// Recursively remove one or more paths.
    func remove(_ paths: [String]) -> String
    /// The user's home directory (absolute).
    func home() -> String
}

extension Shell {
    func command(_ script: String) -> [String] { ["bash", "-lc", script] }

    func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func listDir(_ path: String) -> String { "ls -1Ap \(quote(path)) 2>/dev/null" }

    func find(_ query: String, in dir: String) -> String {
        "find \(quote(dir)) -iname \(quote("*\(query)*")) -printf '%y\\t%p\\n' 2>/dev/null | head -300"
    }

    func readFile(_ path: String) -> String { "cat \(quote(path))" }

    func writeFile(_ path: String, base64 b64: String) -> String {
        // The base64 alphabet has no quote char, so its literal single-quoting is safe.
        "mkdir -p \"$(dirname \(quote(path)))\" && printf '%s' '\(b64)' | base64 -d > \(quote(path))"
    }

    func readFileBase64(_ path: String, capBytes: Int) -> String {
        "head -c \(capBytes) \(quote(path)) 2>/dev/null | base64"
    }

    func base64Capture(capBytes: Int) -> String { "head -c \(capBytes) | base64" }

    func makeDir(_ path: String) -> String { "mkdir -p \(quote(path))" }

    func move(from: String, to: String) -> String { "mv \(quote(from)) \(quote(to))" }

    func copy(from: String, to: String) -> String { "cp -r \(quote(from)) \(quote(to))" }

    // `--` stops option parsing so a path like `-rf` is treated as an operand, not a flag.
    func remove(_ paths: [String]) -> String { "rm -rf -- \(paths.map { quote($0) }.joined(separator: " "))" }

    func home() -> String { "echo $HOME" }
}

/// POSIX shell (bash + coreutils) — the shell on every Linux workspace. Uses all the defaults above.
struct PosixShell: Shell {}
