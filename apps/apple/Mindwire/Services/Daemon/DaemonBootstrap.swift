import Foundation

/// Installs / launches the in-workspace Mindwire runtime (`mindwired`). Two paths, chosen by backend:
///
///  • **Cloud (`installViaUpload`)** — the Oblien runtime-exec path can't do outbound HTTPS, so the
///    *device* downloads the binary (see `DaemonRelease`) and this pushes it into the workspace over
///    the runtime **files API** (base64), then a **local** exec (`base64 -d`/chmod/launch — no
///    network) runs it and waits for `127.0.0.1/healthz` (plain HTTP, fine over exec).
///  • **Self-hosted (`installViaExec`)** — a VPS has normal TLS, so it `curl`s the binary from the
///    release host directly over SSH/exec.
///
/// The caller (`DaemonSession`) owns the *decision* (running vs latest) and the UI messaging. Both
/// paths are atomic (temp + mv) and key success off a `DAEMON_OK` marker, since the runtime exec
/// exit code is unreliable (returns 124 even on success).
enum DaemonBootstrap {
    struct Destination: Sendable {
        let platform: DaemonRelease.Platform
        let arch: String
        let directory: String
        var user: String? = nil
    }

    enum Source {
        case upload(path: String)
        case download
    }

    // MARK: - Cloud: device-download → files-API upload → local launch

    /// Push the device-downloaded binary into a cloud workspace and launch it. `target` is the version
    /// we expect `/healthz` to report once up.
    static func installViaUpload(workspace: WorkspaceService, agentType: String = "",
                                 cwd: String = "", target: String, daemonToken: String,
                                 requireUpdateLease: Bool = false, force: Bool = false,
                                 onProgress: (@Sendable (DaemonInstallProgress) -> Void)? = nil) async throws {
        onProgress?(.preparing)
        let destination = try await probeDestination(workspace)

        // Device downloads the matching workspace binary (device TLS works; the workspace's doesn't).
        // Retries on a dropped/partial transfer and reports progress for the UI bar.
        onProgress?(.downloading(0))
        guard let data = await DaemonRelease.binary(version: target, platform: destination.platform,
                                                   arch: destination.arch,
                                                   onProgress: { onProgress?(.downloading($0)) }) else {
            throw BackendError.message("Couldn't download the Mindwire service. Check your connection and try again.")
        }

        // Push it in as base64 over the runtime files API — no workspace→internet hop.
        let b64Path = "\(destination.directory)/mindwired-\(UUID().uuidString).b64"
        // The runtime files API does not expose transferred bytes. Keep this phase
        // indeterminate instead of displaying a misleading 0% throughout the upload.
        onProgress?(.uploading(nil))
        try await workspace.writeFile(b64Path, content: data.base64EncodedString())

        onProgress?(.starting)
        do {
            try await DaemonStartup.prepare(workspace: workspace, destination: destination, daemonToken: daemonToken,
                                            agentType: agentType, cwd: cwd, requireInstalled: false)
            let script = installScript(destination: destination, source: .upload(path: b64Path),
                                       agentType: agentType, cwd: cwd, target: target, daemonToken: daemonToken,
                                       requireUpdateLease: requireUpdateLease, force: force, bindHost: workspace.daemonBindHost,
                                       supervised: true)
            try await runLaunch(workspace: workspace, script: script)
        } catch {
            // Registration can fail before the install script gets to own/clean this upload.
            try? await workspace.deleteFile(b64Path)
            throw error
        }
    }

    // MARK: - Self-hosted: curl from the release host over exec (VPS has TLS)

    static func installViaExec(workspace: WorkspaceService, agentType: String = "",
                               cwd: String = "", target: String, daemonToken: String,
                               requireUpdateLease: Bool = false, force: Bool = false,
                               onProgress: (@Sendable (DaemonInstallProgress) -> Void)? = nil) async throws {
        onProgress?(.preparing)
        let destination = try await probeDestination(workspace)
        try await DaemonStartup.prepare(workspace: workspace, destination: destination, daemonToken: daemonToken,
                                        agentType: agentType, cwd: cwd, requireInstalled: false)
        let script = installScript(destination: destination, source: .download,
                                   agentType: agentType, cwd: cwd, target: target, daemonToken: daemonToken,
                                   requireUpdateLease: requireUpdateLease, force: force, bindHost: workspace.daemonBindHost,
                                   supervised: true)
        try await runLaunch(workspace: workspace, script: script, onProgress: onProgress)
    }

    static func configureStartup(workspace: WorkspaceService, daemonToken: String) async throws {
        let destination = try await probeDestination(workspace)
        try await DaemonStartup.prepare(workspace: workspace, destination: destination,
                                        daemonToken: daemonToken, requireInstalled: true)
    }

    /// Recovery after VM start: reuse the installed executable, credential and state.
    /// Never download, replace a binary, or terminate another process on this path.
    static func startInstalled(workspace: WorkspaceService, daemonToken: String) async throws {
        let destination = try await probeDestination(workspace)
        try await DaemonStartup.prepare(workspace: workspace, destination: destination,
                                        daemonToken: daemonToken, requireInstalled: true)
        try await runLaunch(workspace: workspace, script: startScript(destination: destination, daemonToken: daemonToken,
                                                                    bindHost: workspace.daemonBindHost, supervised: true))
    }

    static func startScript(destination: Destination, daemonToken: String,
                            port: Int = AppConstants.daemonPort, bindHost: String = "127.0.0.1",
                            supervised: Bool = false) -> String {
        """
        set -euo pipefail
        PORT=\(port)
        VER=''
        DAEMON_TOKEN='\(shArg(daemonToken))'
        DIR='\(shArg(destination.directory))'
        BIN="$DIR/mindwired"
        LOG="$DIR/mindwire.log"
        mkdir -p "$DIR"
        \(installLockScript)
        mw_version=$(running_ver)
        [ -z "$mw_version" ] || { echo "DAEMON_OK $mw_version"; exit 0; }
        mw_status=$(curl -s --connect-timeout 2 --max-time 3 -o /dev/null -w '%{http_code}' \\
          -H "Authorization: Bearer $DAEMON_TOKEN" "http://127.0.0.1:$PORT/healthz" || true)
        [ "$mw_status" = 000 ] || { echo "DAEMON_ERR An existing service on this port did not pass its health check (HTTP $mw_status)." >&2; exit 16; }
        [ -x "$BIN" ] || { echo "DAEMON_NOT_INSTALLED"; exit 15; }
        \(supervised ? "" : detachedLaunch(bindHost: bindHost))
        \(waitForLaunchScript)
        """
    }

    // MARK: - Shared

    private static func probeDestination(_ workspace: WorkspaceService) async throws -> Destination {
        // Runtime exec can strip stdout newlines. Markers survive that transformation.
        let probe = try await workspace.exec(["bash", "-lc",
            "mkdir -p \"$HOME/.mindwire\"; printf '<<OS:%s>><<ARCH:%s>><<DIR:%s>><<USER:%s>>' \"$(uname -s)\" \"$(uname -m)\" \"$HOME/.mindwire\" \"$(id -un)\""])
        return try destination(from: probe.stdout)
    }

    static func destination(from output: String) throws -> Destination {
        guard let os = slice(output, "<<OS:", ">>"),
              let rawArch = slice(output, "<<ARCH:", ">>"),
              let dir = slice(output, "<<DIR:", ">>"), dir.hasPrefix("/"),
              !dir.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BackendError.message("Couldn't read the workspace's operating system and home directory.")
        }
        guard let platform = DaemonRelease.Platform(uname: os), let arch = normalizeArch(rawArch) else {
            throw BackendError.message("The Mindwire service installer doesn't support \(os) on \(rawArch). Use a Linux or macOS workspace with an Intel or ARM64 processor.")
        }
        let user = slice(output, "<<USER:", ">>")
        guard user?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) != true else {
            throw BackendError.message("Couldn't read the workspace's service account.")
        }
        return Destination(platform: platform, arch: arch, directory: dir, user: user)
    }

    /// Both transfer paths share atomic replacement and the supervisor's activation gate.
    static func installScript(destination: Destination, source: Source, agentType: String = "",
                              cwd: String = "", target: String, daemonToken: String,
                              requireUpdateLease: Bool = false, force: Bool = false,
                              port: Int = AppConstants.daemonPort, bindHost: String = "127.0.0.1",
                              supervised: Bool = false) -> String {
        let staging: String
        let acquire: String
        switch source {
        case .upload(let path):
            staging = """
            UPLOAD='\(shArg(path))'
            STAGED="$UPLOAD.tmp"
            """
            // stdin works with both GNU and macOS base64; macOS doesn't accept a positional file.
            acquire = """
            base64 -d < "$UPLOAD" > "$STAGED" 2>/dev/null || { echo "DAEMON_ERR decode-failed (no base64?)" >&2; exit 11; }
            """
        case .download:
            staging = """
            STAGED="$DIR/mindwired-$$.tmp"
            """
            acquire = """
            URL="https://github.com/\(AppConstants.mindwireRepository)/releases/download/v$VER/mindwired-v$VER-\(destination.platform.rawValue)-\(destination.arch)"
            echo 'DAEMON_PROGRESS downloading'
            if ! curl -fSL --progress-bar --connect-timeout 10 --max-time 300 \\
                     --retry 5 --retry-delay 2 --retry-all-errors \\
                     --speed-limit 1024 --speed-time 20 \\
                     -C - "$URL" -o "$STAGED"; then
              echo "DAEMON_ERR download-failed: could not fetch $URL" >&2
              exit 11
            fi
            """
        }
        return """
        set -euo pipefail
        PORT=\(port)
        VER='\(shArg(target))'
        AGENT_TYPE='\(shArg(agentType))'
        AGENT_CWD='\(shArg(cwd))'
        DAEMON_TOKEN='\(shArg(daemonToken))'
        DIR='\(shArg(destination.directory))'
        BIN="$DIR/mindwired"
        LOG="$DIR/mindwire.log"
        REQUIRE_UPDATE_LEASE=\(requireUpdateLease ? "1" : "0")
        FORCE_UPDATE=\(force ? "1" : "0")
        mkdir -p "$DIR"
        \(staging)
        mw_lease=''
        mw_service_pid=''
        mw_lease_file="$DIR/update-lease-$$.json"
        cleanup_update() {
          if [ -n "$mw_lease" ]; then
            curl -s --connect-timeout 2 --max-time 3 -X DELETE \\
              -H "Authorization: Bearer $DAEMON_TOKEN" "http://127.0.0.1:$PORT/service/update/$mw_lease" >/dev/null 2>&1 || true
          fi
          rm -f "$STAGED" "$mw_lease_file"
          [ -z "${UPLOAD:-}" ] || rm -f "$UPLOAD"
        }
        trap cleanup_update EXIT
        \(installLockScript)
        \(skipCurrentVersionScript)

        \(acquire)
        chmod +x "$STAGED"
        \(acquireUpdateLeaseScript)
        echo 'DAEMON_PROGRESS starting'
        \(DaemonStartup.activationLock)
        \(stopDaemonScript)
        sleep 0.4
        mv -f "$STAGED" "$BIN"
        exec 8>&-

        \(supervised ? "" : detachedLaunch(bindHost: bindHost))

        \(waitForLaunchScript)
        """
    }

    private static func detachedLaunch(bindHost: String) -> String {
        """
        \(detachScript)
        "${mw_detach[@]}" /bin/sh -c 'trap "" HUP; exec "$@"' mindwire-service env ADDR="\(shArg(bindHost)):$PORT" AGENT_TYPE="${AGENT_TYPE:-}" AGENT_CWD="${AGENT_CWD:-}" DAEMON_TOKEN="$DAEMON_TOKEN" \\
          STATE_PATH="$DIR/agent-state.json" "$BIN" >>"$LOG" 2>&1 </dev/null 9>&- &
        mw_pid=$!
        """
    }

    /// Runs AFTER download/staging, immediately before stopping the old process.
    /// A lease rejects new work on every client until replacement or its timeout.
    /// Explicit updates can interrupt active work, including on legacy services.
    static let acquireUpdateLeaseScript = """
    mw_running=$(running_ver)
    if [ -n "$mw_running" ]; then
      mw_update_body='{}'
      [ "${FORCE_UPDATE:-0}" = 0 ] || mw_update_body='{"force":true}'
      mw_status=$(curl -s --connect-timeout 2 --max-time 5 -X POST \\
        -H 'Content-Type: application/json' --data "$mw_update_body" \\
        -H "Authorization: Bearer $DAEMON_TOKEN" -o "$mw_lease_file" -w '%{http_code}' \\
        "http://127.0.0.1:$PORT/service/update") || mw_status=000
      case "$mw_status" in
        201)
          mw_lease=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\\([[:alnum:]]*\\)".*/\\1/p' "$mw_lease_file")
          mw_service_pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' "$mw_lease_file")
          [ -n "$mw_lease" ] || { echo 'DAEMON_ERR Could not verify the service update lease.'; exit 17; }
          [[ "$mw_service_pid" =~ ^[0-9]+$ ]] && [ "$mw_service_pid" -gt 1 ] || { echo 'DAEMON_ERR Could not identify the service process.'; exit 17; }
          ;;
        409)
          # A manual upgrade of a legacy service may bypass busy work, but never
          # another installer's lease. The workspace install lock is still held.
          if [ "${FORCE_UPDATE:-0}" != 1 ] || ! grep -q '"code"[[:space:]]*:[[:space:]]*"service_busy"' "$mw_lease_file"; then
            echo 'DAEMON_BUSY'; exit 18
          fi
          ;;
        404)
          [ "$REQUIRE_UPDATE_LEASE" = 0 ] || { echo 'DAEMON_UPDATE_UNSUPPORTED'; exit 19; }
          ;;
        *) echo 'DAEMON_ERR Could not authorize the service restart. Try again shortly.'; exit 17 ;;
      esac
    elif [ "$REQUIRE_UPDATE_LEASE" = 1 ]; then
      echo 'DAEMON_ERR The service went offline before the update. Reconnect and try again.'
      exit 17
    elif [ -x "$BIN" ]; then
      echo 'DAEMON_ERR An installed service could not be checked. Start it before updating.'
      exit 17
    fi
    """

    /// Recheck under the workspace lock: another device may already have installed
    /// this release or a newer one while this device was downloading.
    static let skipCurrentVersionScript = """
    mw_running=$(running_ver)
    if [ "$mw_running" = "$VER" ]; then echo "DAEMON_OK $mw_running"; exit 0; fi
    if [[ "$mw_running" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+$ ]] && [[ "$VER" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+$ ]]; then
      IFS=. read -r mw_major mw_minor mw_patch <<< "$mw_running"
      IFS=. read -r mw_target_major mw_target_minor mw_target_patch <<< "$VER"
      if (( 10#$mw_major > 10#$mw_target_major ||
            (10#$mw_major == 10#$mw_target_major && 10#$mw_minor > 10#$mw_target_minor) ||
            (10#$mw_major == 10#$mw_target_major && 10#$mw_minor == 10#$mw_target_minor && 10#$mw_patch >= 10#$mw_target_patch) )); then
        echo "DAEMON_OK $mw_running"
        exit 0
      fi
    fi
    """

    /// Control markers use stdout: some runtime exec adapters lose trailing stderr on exit.
    /// Capture the child's status and log together so a launch failure is never an empty log tail.
    static let waitForLaunchScript = """
    mw_pid=${mw_pid:-}
    mw_exit=""
    mw_deadline=$((SECONDS + 30))
    while (( SECONDS < mw_deadline )); do
      mw_version=$(running_ver)
      if [ -n "$mw_version" ] && { [ -z "${VER:-}" ] || [ "$mw_version" = "$VER" ]; }; then
        echo "DAEMON_OK $mw_version"
        exit 0
      fi
      if [ -n "$mw_pid" ] && [ -z "$mw_exit" ] && ! kill -0 "$mw_pid" 2>/dev/null; then
        mw_exit=0
        wait "$mw_pid" || mw_exit=$?
        # setsid can fork on Linux. A successful launcher exit is not a daemon failure.
        [ "$mw_exit" = 0 ] || break
      fi
      sleep 0.25
    done
    mw_tail=$(tail -n 30 "$LOG" 2>/dev/null || true)
    if [ -n "$mw_exit" ] && [ "$mw_exit" != 0 ]; then
      mw_reason="Mindwire exited during startup (status $mw_exit)."
    else
      mw_status=$(curl -s --connect-timeout 2 --max-time 3 -o /dev/null -w '%{http_code}' \\
        -H "Authorization: Bearer $DAEMON_TOKEN" "http://127.0.0.1:$PORT/healthz" || true)
      mw_reason="The Mindwire service did not become ready (health HTTP $mw_status)."
    fi
    [ -z "$mw_tail" ] || mw_reason="$mw_reason $mw_tail"
    printf 'DAEMON_ERR %s\\n' "$mw_reason"
    exit 12
    """

    /// Stop the leased PID. Legacy services use the listener PID, or the sole daemon
    /// process on minimal Linux images. Never terminate every instance on a host.
    static let stopDaemonScript = """
    mw_stopping_pid=''
    if [ -n "${mw_service_pid:-}" ]; then
      mw_stopping_pid="$mw_service_pid"
    elif [ -z "${mw_running:-}" ]; then
      : # First installation: no existing service to stop.
    else
      if command -v lsof >/dev/null 2>&1; then
        mw_candidates=$(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u || true)
      elif command -v pgrep >/dev/null 2>&1; then
        mw_candidates=$(pgrep -x mindwired || true)
      else
        mw_candidates=''
        for mw_proc in /proc/[0-9]*/comm; do
          IFS= read -r mw_name 2>/dev/null < "$mw_proc" || continue
          [ "$mw_name" = mindwired ] || continue
          mw_pid=${mw_proc#/proc/}; mw_pid=${mw_pid%/comm}
          mw_candidates="$mw_candidates $mw_pid"
        done
      fi
      set -- $mw_candidates
      [ "$#" = 1 ] && [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 1 ] || { echo 'DAEMON_ERR Could not identify a single service process to update safely.'; exit 17; }
      mw_stopping_pid="$1"
    fi
    if [ -n "$mw_stopping_pid" ]; then
      mw_process_identity=$(ps -p "$mw_stopping_pid" -o lstart= -o comm= 2>/dev/null || true)
      kill "$mw_stopping_pid" 2>/dev/null || true
      for mw_attempt in {1..60}; do
        kill -0 "$mw_stopping_pid" 2>/dev/null || break
        sleep 0.25
      done
      if kill -0 "$mw_stopping_pid" 2>/dev/null; then
        mw_current_identity=$(ps -p "$mw_stopping_pid" -o lstart= -o comm= 2>/dev/null || true)
        [ -n "$mw_process_identity" ] && [ "$mw_current_identity" = "$mw_process_identity" ] || {
          echo 'DAEMON_ERR Could not verify the service process during restart.'; exit 17;
        }
        kill -KILL "$mw_stopping_pid" 2>/dev/null || true
        for mw_attempt in {1..20}; do
          kill -0 "$mw_stopping_pid" 2>/dev/null || break
          sleep 0.1
        done
        if kill -0 "$mw_stopping_pid" 2>/dev/null; then
          echo 'DAEMON_ERR The previous service did not stop.'; exit 17
        fi
      fi
    fi
    """

    /// The lock lives in the workspace, so two app instances cannot replace the binary together.
    /// Linux flock and macOS lockf both hold a BSD flock on the inherited descriptor. The lock
    /// releases on exit/crash; never unlink its file (waiters must lock the same inode).
    static let installLockScript = """
    exec 9>"$DIR/daemon-install.lock"
    if command -v flock >/dev/null 2>&1; then
      flock -w 360 9 || { echo "DAEMON_ERR another daemon update is still running" >&2; exit 13; }
    elif command -v lockf >/dev/null 2>&1; then
      lockf -s -t 360 9 || { echo "DAEMON_ERR another daemon update is still running" >&2; exit 13; }
    else
      echo "DAEMON_ERR No supported update lock is available (flock on Linux, lockf on macOS)." >&2
      exit 13
    fi
    # Another device may have completed first. Reuse its workspace credential under the lock.
    if [ -s "$DIR/daemon.token" ]; then DAEMON_TOKEN=$(cat "$DIR/daemon.token"); fi
    running_ver() {
      curl -fsS --connect-timeout 2 --max-time 3 -H "Authorization: Bearer $DAEMON_TOKEN" \
        "http://127.0.0.1:$PORT/healthz" 2>/dev/null \\
        | sed -n 's/.*"version":"\\([^"]*\\)".*/\\1/p' || true
    }
    """

    /// macOS ships Perl's POSIX setsid, but not the Linux setsid command. Start a separate session
    /// in either case so ending the SSH/runtime exec cannot take the daemon down with its shell.
    /// The child ignores HUP directly: macOS nohup can fail after setsid on a headless image.
    static let detachScript = """
    if command -v setsid >/dev/null 2>&1; then
      mw_detach=(setsid)
    elif command -v perl >/dev/null 2>&1; then
      mw_detach=(perl -MPOSIX -e 'defined(my $sid = POSIX::setsid()) && $sid >= 0 or die "setsid: $!"; exec @ARGV; die "exec: $!";')
    else
      echo "DAEMON_ERR Cannot start the Mindwire service: setsid or Perl is required." >&2
      exit 14
    fi
    """

    static func runLaunch(workspace: WorkspaceService, script: String,
                                  onProgress: (@Sendable (DaemonInstallProgress) -> Void)? = nil) async throws {
        let combined: String
        if let onProgress {
            var output = Data(), reader = DaemonInstallOutput()
            for try await event in workspace.execStream(["bash", "-lc", script]) {
                guard case .output(let data) = event else { continue }
                reader.receive(data).forEach(onProgress)
                output.append(data)
                // Keep diagnostics bounded when curl reports many transfer updates.
                if output.count > 65_536 { output.removeFirst(output.count - 65_536) }
            }
            combined = String(decoding: output, as: UTF8.self)
        } else {
            let result = try await workspace.exec(["bash", "-lc", script])
            combined = [result.stdout, result.stderr].joined(separator: "\n")
        }
        if let ok = combined.range(of: "DAEMON_OK") {
            APILog.note("daemon install ✓ \(String(combined[ok.lowerBound...]).oneLine())")
            return
        }
        if combined.contains("DAEMON_NOT_INSTALLED") { throw DaemonBootstrapError.notInstalled }
        if combined.contains("DAEMON_BUSY") { throw DaemonUpdateError.busy }
        if combined.contains("DAEMON_UPDATE_UNSUPPORTED") { throw DaemonUpdateError.unsupported }
        let reason = failureReason(combined)
        APILog.note("daemon install ✗ \(reason.oneLine())")
        throw BackendError.message(reason)
    }

    /// Extract the text between `open` and the next `close` marker. Newline-independent, so it
    /// survives the runtime-exec stdout newline stripping.
    private static func slice(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open) else { return nil }
        guard let b = s.range(of: close, range: a.upperBound..<s.endIndex) else { return nil }
        let inner = s[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    private static func normalizeArch(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "x86_64", "amd64": return "amd64"
        case "aarch64", "arm64": return "arm64"
        default: return nil
        }
    }

    /// Extract the user-facing failure reason from the script output (`DAEMON_ERR …` + log tail).
    private static func failureReason(_ output: String) -> String {
        if let r = output.range(of: "DAEMON_ERR") {
            let detail = output[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Couldn't start the Mindwire service." : detail
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Couldn't start the Mindwire service." : trimmed
    }

    /// Escape a value for embedding inside a single-quoted shell literal.
    static func shArg(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

}

extension String {
    /// Trim + collapse to one line for a tidy console log.
    func oneLine() -> String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "<empty>" : t.replacingOccurrences(of: "\n", with: " ⏎ ")
    }
}
