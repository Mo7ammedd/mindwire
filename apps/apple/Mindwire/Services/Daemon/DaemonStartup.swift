import Foundation

/// Providers with their own process manager (Oblien) register the same foreground runner
/// used by systemd/launchd. Pairing has a separate, existing guardian and bypasses bootstrap.
protocol DaemonSupervisor: Sendable {
    func ensureRunning(destination: DaemonBootstrap.Destination) async throws
}

enum DaemonStartup {
    /// Configure before replacing anything. A manager may adopt a legacy process without
    /// stopping it; the runner waits until that process exits before taking ownership.
    static func prepare(workspace: WorkspaceService, destination: DaemonBootstrap.Destination,
                        daemonToken: String, agentType: String = "", cwd: String = "",
                        requireInstalled: Bool) async throws {
        try await DaemonBootstrap.runLaunch(workspace: workspace,
            script: configurationScript(destination: destination, daemonToken: daemonToken,
                agentType: agentType, cwd: cwd, bindHost: workspace.daemonBindHost,
                requireInstalled: requireInstalled))
        if let supervisor = workspace.daemonSupervisor {
            try await supervisor.ensureRunning(destination: destination)
        } else {
            try await DaemonBootstrap.runLaunch(workspace: workspace,
                script: nativeRegistrationScript(destination: destination,
                    nativeServices: workspace.usesNativeDaemonService))
        }
    }

    static func configurationScript(destination: DaemonBootstrap.Destination, daemonToken: String,
                                    agentType: String = "", cwd: String = "", bindHost: String = "127.0.0.1",
                                    requireInstalled: Bool, port: Int = AppConstants.daemonPort) -> String {
        let q = DaemonBootstrap.shArg
        return """
        set -euo pipefail
        umask 077
        PORT=\(port)
        DIR='\(q(destination.directory))'
        DAEMON_TOKEN='\(q(daemonToken))'
        mkdir -p "$DIR"
        \(DaemonBootstrap.installLockScript)
        \(requireInstalled ? "[ -x \"$DIR/mindwired\" ] || { echo DAEMON_NOT_INSTALLED; exit 15; }" : "")
        [ -n "$DAEMON_TOKEN" ] || { echo 'DAEMON_ERR The Mindwire credential is missing. Reconnect before setting up the service.'; exit 16; }
        [ -s "$DIR/daemon.token" ] || printf '%s' "$DAEMON_TOKEN" > "$DIR/daemon.token"
        chmod 600 "$DIR/daemon.token"
        mw_config="$DIR/service.env"
        if [ ! -s "$mw_config" ]; then
          {
            printf 'export HOME=%q\\n' "$HOME"
            printf 'export PATH=%q\\n' "$PATH"
            printf 'export ADDR=%q\\n' '\(q(bindHost)):\(port)'
            printf 'export AGENT_TYPE=%q\\n' '\(q(agentType))'
            printf 'export AGENT_CWD=%q\\n' '\(q(cwd))'
          } > "$mw_config.tmp"
          mv -f "$mw_config.tmp" "$mw_config"
        fi
        cat > "$DIR/service-runner.sh.tmp" <<'MINDWIRE_RUNNER'
        \(runner)
        MINDWIRE_RUNNER
        chmod 700 "$DIR/service-runner.sh.tmp"
        if cmp -s "$DIR/service-runner.sh.tmp" "$DIR/service-runner.sh"; then
          rm -f "$DIR/service-runner.sh.tmp"
        else
          mv -f "$DIR/service-runner.sh.tmp" "$DIR/service-runner.sh"
        fi
        echo DAEMON_OK startup-configured
        """
    }

    /// This lock is separate from the complete install transaction. A manager can launch
    /// the replacement while the installer still owns fd 9 and verifies its health.
    static let activationLock = #"""
    exec 8>"$DIR/daemon-activation.lock"
    if command -v flock >/dev/null 2>&1; then
      flock -w 360 8 || { echo 'DAEMON_ERR Service activation is still in progress.'; exit 13; }
    else
      lockf -s -t 360 8 || { echo 'DAEMON_ERR Service activation is still in progress.'; exit 13; }
    fi
    """#

    /// A single daemon holds fd 7 for its lifetime. Managers block on that descriptor
    /// without polling. The short health loop exists only while adopting an old detached
    /// installation or waiting for a first download; normal operation execs mindwired.
    static let runner = #"""
    #!/bin/bash
    set -euo pipefail
    umask 077
    DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
    mw_lock() {
      if command -v flock >/dev/null 2>&1; then flock "$@";
      else
        if [ "${1:-}" = -n ]; then shift; lockf -s -t 0 "$@";
        else lockf -s "$@"; fi
      fi
    }
    # Minimal hosts/containers without a native manager still recover from a process
    # crash. Only one guardian can exist, including across concurrent mobile clients.
    if [ "${1:-}" = --supervise ]; then
      exec 6>"$DIR/daemon-guardian.lock"
      mw_lock -n 6 || exit 0
      mw_child=''
      mw_shutdown() {
        trap '' TERM INT
        if [ -n "$mw_child" ]; then
          kill "$mw_child" 2>/dev/null || true
          wait "$mw_child" || true
        fi
        exit 0
      }
      trap mw_shutdown TERM INT
      while :; do
        /bin/bash "$0" 6>&- &
        mw_child=$!
        wait "$mw_child" || true
        mw_child=''
        sleep 2
      done
    fi
    exec 7>"$DIR/daemon-run.lock"
    mw_lock 7
    while :; do
      exec 8>"$DIR/daemon-activation.lock"
      mw_lock 8
      . "$DIR/service.env"
      DAEMON_TOKEN=$(cat "$DIR/daemon.token")
      [ -n "$DAEMON_TOKEN" ] || { echo 'Mindwire service credential is missing.' >&2; exit 1; }
      export DAEMON_TOKEN
      export STATE_PATH="$DIR/agent-state.json"
      PORT=${ADDR##*:}
      if [ -x "$DIR/mindwired" ]; then
        mw_status=$(curl -s --connect-timeout 2 --max-time 3 -o /dev/null -w '%{http_code}' \
          -H "Authorization: Bearer $DAEMON_TOKEN" "http://127.0.0.1:$PORT/healthz") || mw_status=000
        if [ "$mw_status" = 000 ]; then
          # Close separately: macOS Bash can leak its saved redirection descriptor
          # across `exec command 8>&-`, which would hold the activation lock forever.
          exec 8>&-
          exec "$DIR/mindwired"
        fi
        if [ "$mw_status" != 200 ]; then
          echo "Mindwire cannot adopt the existing listener (health HTTP $mw_status)." >&2
          exit 1
        fi
      fi
      exec 8>&-
      sleep 2
    done
    """#

    /// Native services run as the SSH account, never as a more privileged account.
    /// With no boot manager/access, retain a small singleton guardian and app recovery.
    static func nativeRegistrationScript(destination: DaemonBootstrap.Destination,
                                         nativeServices: Bool = true) -> String {
        let q = DaemonBootstrap.shArg
        let runner = destination.directory + "/service-runner.sh"
        let systemdPath = runner.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "$", with: "$$")
        let xmlPath = xml(runner)
        let xmlLog = xml(destination.directory + "/mindwire.log")
        return """
        set -euo pipefail
        umask 077
        DIR='\(q(destination.directory))'
        PORT=\(AppConstants.daemonPort)
        DAEMON_TOKEN=''
        \(DaemonBootstrap.installLockScript)
        mw_uid=$(id -u)
        mw_user=$(id -un)
        mw_admin=(env)
        if [ "$mw_uid" = 0 ]; then mw_can_admin=1
        elif [ \(nativeServices ? "1" : "0") = 1 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then mw_admin=(sudo -n); mw_can_admin=1
        else mw_can_admin=0; fi
        if [ \(nativeServices ? "1" : "0") = 1 ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
          mw_unit="mindwire-workspace-$mw_uid.service"
          if [ "$mw_can_admin" = 1 ]; then
            mw_units=/etc/systemd/system
            mw_systemctl=("${mw_admin[@]}" systemctl)
            mw_user_line="User=$mw_user"
            mw_target=multi-user.target
          elif systemctl --user show-environment >/dev/null 2>&1; then
            mw_linger=$(loginctl show-user "$mw_uid" -p Linger --value 2>/dev/null || true)
            if [ "$mw_linger" != yes ]; then loginctl --no-ask-password enable-linger "$mw_user" </dev/null >/dev/null 2>&1 || true; fi
            mw_linger=$(loginctl show-user "$mw_uid" -p Linger --value 2>/dev/null || true)
            if [ "$mw_linger" = yes ]; then
              mw_units="$HOME/.config/systemd/user"
              mkdir -p "$mw_units"
              mw_systemctl=(systemctl --user)
              mw_user_line=''
              mw_target=default.target
            fi
          fi
          if [ -n "${mw_units:-}" ]; then
            {
              cat <<'MINDWIRE_UNIT'
        [Unit]
        Description=Mindwire workspace service
        After=network.target
        StartLimitIntervalSec=0
        [Service]
        Type=simple
        ExecStart=/bin/bash "\(systemdPath)"
        Restart=always
        RestartSec=2
        KillMode=mixed
        TimeoutStopSec=20
        UMask=0077
        MINDWIRE_UNIT
              printf '%s\\n' "$mw_user_line" '[Install]' "WantedBy=$mw_target"
            } > "$DIR/service.unit.tmp"
            if ! cmp -s "$DIR/service.unit.tmp" "$mw_units/$mw_unit"; then
              "${mw_admin[@]}" install -m 644 "$DIR/service.unit.tmp" "$mw_units/$mw_unit"
              "${mw_systemctl[@]}" daemon-reload
            fi
            rm -f "$DIR/service.unit.tmp"
            "${mw_systemctl[@]}" enable "$mw_unit" >/dev/null
            "${mw_systemctl[@]}" start "$mw_unit"
            printf '%s' systemd > "$DIR/service-manager"
            echo DAEMON_OK systemd
            exit 0
          fi
        fi
        if [ \(nativeServices ? "1" : "0") = 1 ] && [ "$(uname -s)" = Darwin ] && command -v launchctl >/dev/null 2>&1; then
          mw_label="sh.mindwire.workspace.$mw_uid"
          mw_domain="gui/$mw_uid"
          mw_plist_dir="$HOME/Library/LaunchAgents"
          mw_launchctl=(launchctl)
          mw_user_xml=''
          if [ "$mw_can_admin" = 1 ]; then
            mw_domain=system
            mw_plist_dir=/Library/LaunchDaemons
            mw_launchctl=("${mw_admin[@]}" launchctl)
            mw_user_xml="<key>UserName</key><string>$mw_user</string>"
          fi
          if [ "$mw_can_admin" = 1 ] || launchctl print "$mw_domain" >/dev/null 2>&1; then
            {
              cat <<'MINDWIRE_PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>ProgramArguments</key><array><string>/bin/bash</string><string>\(xmlPath)</string></array>
        <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
        <key>ThrottleInterval</key><integer>2</integer>
        <key>ExitTimeOut</key><integer>20</integer>
        <key>StandardOutPath</key><string>\(xmlLog)</string>
        <key>StandardErrorPath</key><string>\(xmlLog)</string>
        MINDWIRE_PLIST
              printf '%s\\n' "<key>Label</key><string>$mw_label</string>" "$mw_user_xml" '</dict></plist>'
            } > "$DIR/service.plist.tmp"
            "${mw_admin[@]}" mkdir -p "$mw_plist_dir"
            if ! cmp -s "$DIR/service.plist.tmp" "$mw_plist_dir/$mw_label.plist"; then
              "${mw_admin[@]}" install -m 644 "$DIR/service.plist.tmp" "$mw_plist_dir/$mw_label.plist"
            fi
            rm -f "$DIR/service.plist.tmp"
            "${mw_launchctl[@]}" enable "$mw_domain/$mw_label"
            if ! "${mw_launchctl[@]}" print "$mw_domain/$mw_label" >/dev/null 2>&1; then
              "${mw_launchctl[@]}" bootstrap "$mw_domain" "$mw_plist_dir/$mw_label.plist"
            fi
            "${mw_launchctl[@]}" kickstart "$mw_domain/$mw_label"
            printf '%s' launchd > "$DIR/service-manager"
            echo DAEMON_OK launchd
            exit 0
          fi
        fi
        \(DaemonBootstrap.detachScript)
        "${mw_detach[@]}" /bin/sh -c 'trap "" HUP; exec "$@"' mindwire-service /bin/bash "$DIR/service-runner.sh" --supervise \\
          >> "$DIR/mindwire.log" 2>&1 </dev/null 9>&- &
        printf '%s' background > "$DIR/service-manager"
        echo DAEMON_OK background
        """
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
