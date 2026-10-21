#!/usr/bin/env bash
# Start a branch build with separate state, reachable from a phone on the same network.
set -euo pipefail
umask 077

handoff_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
handoff_dir="${HANDOFF_UI_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mindwire-handoff-ui}"
handoff_addr="${ADDR:-0.0.0.0:8795}"
mkdir -p "$handoff_dir"
chmod 700 "$handoff_dir"

# Keep one writer per test store. The daemon keeps this descriptor after exec.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$handoff_dir/launcher.lock"
  if ! flock -n 9; then
    printf 'The handoff UI is already running. Its token file is %s/daemon.token\n' "$handoff_dir" >&2
    exit 1
  fi
fi

printf 'Building the handoff UI and daemon…\n'
go -C "$handoff_root/packages/daemon" build -o "$handoff_dir/mindwired" ./cmd/daemon
if [[ ! -s "$handoff_dir/daemon.token" ]]; then
  openssl rand -hex 32 >"$handoff_dir/daemon.token"
fi
chmod 600 "$handoff_dir/daemon.token"
export DAEMON_TOKEN="$(<"$handoff_dir/daemon.token")"
export ADDR="$handoff_addr"
export STATE_PATH="$handoff_dir/state.json"
export WORKSPACE_DB_PATH="$handoff_dir/workspace.db"
export AGENT_CWD="${AGENT_CWD:-$handoff_root}"

printf '\nOpen http://YOUR_COMPUTER_IP:%s/ui/ on your phone.\n' "${handoff_addr##*:}"
printf 'Access token file: %s/daemon.token\n' "$handoff_dir"
printf 'This test service uses its own state. Ctrl+C stops it.\n\n'
exec "$handoff_dir/mindwired"
