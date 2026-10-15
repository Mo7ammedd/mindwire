#!/bin/bash
set -euo pipefail
git_check_root=$(cd "$(dirname "$0")/.." && pwd)
git_check_binary=$(mktemp -t mindwire-git-history)
trap 'rm -f "$git_check_binary"' EXIT
cd "$git_check_root"
swiftc -parse-as-library \
  Mindwire/Models/Git.swift \
  Mindwire/Models/GitOperation.swift \
  Mindwire/Models/GitHub.swift \
  Mindwire/Models/GitPullRequest.swift \
  Mindwire/Services/Ports/GitService.swift \
  Mindwire/Services/Ports/RequestCancellation.swift \
  Mindwire/Services/Ports/Shell.swift \
  Mindwire/Services/Git/ExecGitService.swift \
  Mindwire/Services/Git/ExecGitHistory.swift \
  scripts/GitHistoryCheck.swift -o "$git_check_binary"
"$git_check_binary"
