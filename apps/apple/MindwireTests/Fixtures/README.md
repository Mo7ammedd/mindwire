# Codex protocol captures

These are the Mindwire daemon's normalized events and messages from authenticated
codex-cli 0.154.0 runs on 2026-09-13. The raw, sanitized CLI and native-transcript
captures live in the sibling `mindwire` repository under
`packages/daemon/internal/agent/codex/testdata/live-0.154.0/`.

The daemon's `TestCaptured` tests export these with `CODEX_CAPTURE_EXPORT` set to an
existing directory. Files are named `hello.json`, `activity.json`, `structured.json`,
and `plan.json`; the iOS copies add the `codex-` prefix and omit transient `at`
timestamps. `ChatRunTests` consumes them through the regular shared chat models.

`codex-questions.json` and `claude-code-questions.json` were captured from the daemon API using Codex CLI 0.154.0 and Claude Code 2.1.246 on 2026-09-15. Both native forms were answered through `/runs/{id}/respond`, including per-question feedback and Claude multiple selections; the native turns then finished successfully. These fixtures contain no credentials.
