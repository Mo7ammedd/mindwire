# Queued chat input and physical iPhone notifications

Validated 6 October 2026 on the connected iPhone 12. The updated signed development app is installed and was reopened after testing.

- Paired Mac preparation configured the actual running daemon over its saved SSH connection. The daemon PID remained 84605; native sessions were not restarted.
- Real APNs delivery passed for Codex completion, Claude approval, and Codex error. Each relay request delivered to exactly the physical phone running the check. The app verified native receipt, communication presentation, and chat routing. The temporary send credential was deleted.
- Generic send credentials now cover paired computers, SSH servers, and containers. Cloud credentials keep their workspace scope. Account credentials and FCM device tokens are never installed on the daemon.
- The workspace status accessory is centered before the native chevron; see workspace-status-iphone.png.
- 97 notification/chat regression checks passed on the physical iPhone. The two remaining screenshot checks passed after replacing absolute /tmp exports with XCTest attachments; their images are included here. No production chat behavior changed for that test export fix.
- Real Codex and Claude executable tests passed through the production daemon API using isolated local model responses: two follow-ups (including an image), receipt retry, one native conversation, one final result, and correct reopened history.
- Go race tests, vet and build passed locally, excluding the separate optional TestLiveClaude external-gateway test. The new native Codex/Claude integration checks both passed.
- TypeScript SDK typecheck/build and 204 tests passed (20 optional skips); web and console production builds passed.

Daemon queued-input support shipped in [Mindwire 0.1.44](https://github.com/oblien/mindwire/releases/tag/v0.1.44), through [PR #32](https://github.com/oblien/mindwire/pull/32). All PR and release checks passed. The Mac CLI and service were updated to 0.1.44 while idle; the saved computer identity and SSH fingerprint were preserved. Its live health response advertises queuedInputVersion 1 and attachmentUploadVersion 1.
