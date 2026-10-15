#!/usr/bin/env bash
# Shared launcher for the runtime, console, website, and protocol lab.
set -euo pipefail
mindwire_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  all) shift; set -- daemon console web "$@" ;;
  mindwire) shift; set -- daemon "$@" ;;
esac
exec node "$mindwire_root/scripts/dev.mjs" "$@"
