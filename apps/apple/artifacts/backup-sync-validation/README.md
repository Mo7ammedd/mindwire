# Backup and chat validation — October 7, 2026

These screenshots use fictional local fixtures, the production UI and sync service, and an in-memory cloud adapter. They contain no real server credentials or Apple Account data.

| Check | Result |
| --- | --- |
| Signed iOS device build | Passed |
| Simulator build | Passed |
| Connection backup and sync tests | 20 passed |
| Chat lifecycle, queued input, reconnection and run tests | 107 passed |
| Push registration, presentation, workspace delivery, lifecycle and reminder tests | 36 passed |
| iPhone and iPad Settings, confirmation and chat-loading UI | Passed |
| Encrypted backup export/import through native Files, on both devices | Passed |
| Optional notification sign-in sheet and truthful delivery status, iPhone/iPad | Passed in light/dark fixtures |
| Independent older/newer history loading, iPhone/iPad | Passed |
| Physical iPhone push diagnostic | Current install is signed out; live delivery requires sign-in |
| Daemon race tests, vet and build | Passed; external authenticated `TestLiveClaude` excluded locally |
| TypeScript SDK typecheck, build and unit tests | Passed; 209 tests passed, 21 E2E tests skipped |
| Mindwire documentation production build | Passed |
| Physical iPhone CloudKit backup/restore | Deferred: Apple returned `Quota exceeded` |
| CloudKit Production schema deployment | Not performed |

The file test saves outside the app container, relaunches, opens the file through Browse → On My iPhone/iPad, checks the wrong-password response, then decrypts and restores without duplicating existing connections. Model tests separately exercise a fresh library and a new device, optional credentials, corrupted files, workspace collisions and missing-credential recovery.

The initial combined unit run hit one existing fixed-delay layout assertion while another simulator's UI checks ran. That assertion passed three isolated repetitions unchanged, and the final serial suite passed all 120 tests.

The subsequent chat and notification checks passed 143 unique model tests (133 in the main run, then 36 focused checks including nine additional reconnection tests, and five reminder checks including a new multiwindow ownership case). Together with the 20 backup/sync checks, this covers 163 tests. Rapid Back/Open shares an outstanding read, the chat list retains its loading ring, older pages remain independent of latest validation, and sending adopts any newer page before appending the acknowledged message.

The paging UI test matches the native activity indicator's animation value in one accessibility snapshot. UITableView can retain a stopped, offscreen header in its accessibility tree; its existence alone is not a loading signal. The production header removes its indicator after completion and preserves the reader's visible message. iPad checks use the adaptive navigation container rather than assuming an iPhone tab bar.

## Screenshots

| Screen | iPhone | iPad |
| --- | --- | --- |
| Dark settings | [View](iphone/ACAF748E-C0AB-4509-82C5-BA28D82159D3.png) | [View](ipad/C8AB7F5D-280C-4EA2-9CC4-6D24DA33B7C9.png) |
| Light settings | [View](iphone/570ADBDD-E469-40FE-B040-4DA1CD2421B6.png) | [View](ipad/3FCD10F1-81EE-4785-8BEA-353247AFF2C0.png) |
| Chat title indicator | [View](iphone/C022EA54-1841-4839-A8CE-F546FAC094E3.png) | [View](ipad/D7F96C80-F74F-45CA-94BC-93CC42A1151B.png) |
| Native Files picker | [View](iphone-file-roundtrip/93E1064E-1BCB-42F6-A1EC-B3EC3757A46F.png) | [View](ipad-file-roundtrip/4D463C31-EB9E-4747-B4A3-69418C59DAEA.png) |
| Decrypted restore preview | [View](iphone-file-roundtrip/0ACB2F2F-7DFD-48BF-AF58-D39FDC4A74B5.png) | [View](ipad-file-roundtrip/765018AF-BA6B-426E-ABCA-3BBAD5ABAE96.png) |
| Notification connection, dark | [View](notifications-iphone/FCC2F596-6EFF-4901-BCF0-4F7CA3DE37E2.png) | [View](notifications-ipad/B00BC785-53CD-49D2-96D2-6277452F6A24.png) |
| Notification connection, light | [View](notifications-iphone/606EE3FB-BB98-4C6C-95A1-6CA4BB003F60.png) | [View](notifications-ipad/59376B6F-B677-46A8-A2E4-E9EE804B8E5F.png) |
| Permission versus delivery | [View](notifications-iphone/009FFDEC-002F-405C-94C2-9509E9F759D6.png) | [View](notifications-ipad/28084814-4C54-4DC6-B3A7-8F34F472ABA5.png) |
| Older paging during latest validation | [View](notifications-iphone/1BD609F7-8378-4CEE-98EB-E1F1493A1C2E.png) | [View](notifications-ipad/E49334AC-FBF7-4B1E-9900-3096E26D3CD2.png) |

Each directory contains Xcode's attachment manifest. Secure text fields are redacted in system screenshots.

## Local result bundles

- `/tmp/MindwireBackupAndChatSerialFinal-20261007.xcresult`
- `/tmp/MindwireBackupIPhone-20261007.xcresult`
- `/tmp/MindwireBackupIPadFinal-20261007.xcresult`
- `/tmp/MindwireBackupFileRoundTripIPhoneV2-20261007.xcresult`
- `/tmp/MindwireBackupFileRoundTripIPad-20261007.xcresult`
- `/tmp/MindwireChatIndependentPagingModels-20261007.xcresult`
- `/tmp/MindwireNotificationsAndChatModels-20261007.xcresult`
- `/tmp/MindwireNotificationRecoveryAndReconnectionFinal-20261007.xcresult`
- `/tmp/MindwireNotificationReminderFinal-20261007.xcresult`
- `/tmp/MindwireNotificationsAndChatUIIPhoneV2-20261007.xcresult`
- `/tmp/MindwireNotificationsAndChatUIIPadV2-20261007.xcresult`
- `/tmp/MindwireICloudLive-20261007.xcresult` — quota failure, not a passed restore test.

Production setup and recovery behavior are documented in [BackupSync.md](../../docs/BackupSync.md). Conditional history validation requires releasing the companion daemon changes; existing daemons retain their compatible newest-page path. No daemon release, live service restart or App Store upload was performed for this change.
