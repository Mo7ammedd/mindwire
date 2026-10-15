# Connection backup and sync

Settings → Backup & Sync is the entry point. iCloud Sync is opt-in on a fresh account. Once a backup exists, a fresh install on the same Apple Account discovers it and restores computers, SSH servers, their workspace links, and the explicitly allowlisted app preferences. Projects, project folders, files and native conversations remain on the workspace daemon; reconnecting loads their authoritative state.

## iCloud

`ConnectionSyncService` uses `CKSyncEngine` with the private database in `iCloud.com.oblien.mindwire`. One custom zone, `MindwireConnections`, contains `MindwireConnection` records. The `payload` field is encrypted data; opaque record names do not reveal server addresses. A settings record records the account's opt-in and credential preference.

Each connection and its workspace links form one record. Per-record logical clocks, CloudKit change tags, tombstones and a durable outbox preserve offline edits and merge changes from other devices. Received records have an unapplied journal before they update local lists. An interrupted restore replays before detecting local deletions. Repeated refreshes share one request; user changes queue behind it. Apple handles subscriptions, backoff and automatic retries. Foreground and manual Sync Now also fetch changes. There is no polling timer.

Switching Apple Accounts pauses the previous account's sync. Explicitly enabling the new account is required before uploading local connections. Deleting iCloud Data removes the custom zone and synchronized server credential copies, keeps local data, and turns sync off as other devices observe the deletion. Existing engines never automatically recreate a deleted zone. Removing a saved connection while sync is enabled removes it from synced devices; remote workspace files and processes remain untouched.

Server passwords and private SSH keys use a separate synchronizable iCloud Keychain service only when **Sync Server Credentials** is enabled. Its records are scoped to the CloudKit user identity. Computer keys, daemon tokens, discovery secrets and phone approvals stay in the device-only Keychain. Same-device reinstall can reuse retained approval metadata and keys. A different device restores the computer card with **Approve This Device** and the existing QR pairing flow. Missing server credentials open the existing authentication editor.

iCloud quota and network failures leave the local connections and outbox intact. Settings explains the cause, and a successful automatic retry clears the error. Actual cross-device Keychain delivery depends on the user's Passwords & Keychain settings; a successful local Keychain write is not proof that another device has downloaded it.

## Encrypted files

**Save Backup** creates a `.mindwirebackup` file through the native Files exporter. The user chooses a password of at least 12 characters and optionally includes server credentials. AES-256-GCM authenticates and encrypts the complete backup, using a fresh salt and nonce and PBKDF2-HMAC-SHA256 with 600,000 iterations. Key derivation runs off the main thread. Only ciphertext reaches the document provider or temporary export file. Readers bound the file size, format and KDF parameters before expensive processing.

**Restore Backup** uses the native file importer and security-scoped URL access. Decryption and validation happen before the import preview. Import adds missing connections, preserves existing addresses and credentials, and optionally restores preferences. It never imports another phone's computer approval. A local journal completes multi-list updates after an interrupted restore. No remote commands or file deletions run during import.

iOS removes an app's own sandbox when the app is deleted. Users must save a reinstall-safe file outside Mindwire's folder: an available local Files location, another document provider or external storage. Saving to iCloud Drive still requires available iCloud storage. Mindwire cannot silently write anywhere outside its sandbox without the user's document-picker selection. File backups are manual snapshots; iCloud remains the automatic sync option.

## Provisioning and validation

The app declares CloudKit container access, APNs and the `remote-notification` background mode. CloudKit notifications are restricted to the production zone's subscription so disposable live test zones cannot trigger synchronization of the user's actual library. No user-facing notification permission is needed for silent iCloud updates.

Before distributing the feature through TestFlight or the App Store, create/verify the development schema and deploy it to **Production** in Apple's CloudKit Console for `iCloud.com.oblien.mindwire`. The record type is `MindwireConnection`, with the encrypted data field `payload`. The SDK creates this schema on a successful development write; the production environment does not create record types automatically. Xcode automatic signing provisioned the container successfully. Production schema promotion has not been performed from this checkout.

`ConnectionSyncTests` covers opt-in, reinstall and new-device recovery, independent additions, deletions, offline outboxes, account changes, operation serialization, quota recovery and interrupted imports. `ConnectionFileBackupTests` covers encrypted file round trips, credential isolation, tampering, incorrect passwords, idempotent restores and collision rejection. `BackupSyncInteractionTests` drives the production Settings and chat screens on iPhone/iPad fixtures. These fixtures never access the user's Apple Account.

Validation on October 7, 2026 passed the signed iOS device build and simulator build, all 20 backup/sync tests, and 107 chat lifecycle, queue, reconnect and run tests. Native UI checks passed on iPhone 17 Pro Max and iPad Pro 13-inch simulators in iOS 26.5: light/dark sync controls, the delete confirmation, retained chat content with title-only refresh and independent scroller-based older paging, and password-protected export/import through Files. The file round trip includes relaunching the app, browsing local storage, retrying an incorrect password and preserving existing connections. The exported file was verified in the system file provider's storage, outside Mindwire's app container. Screenshots and result references are in `apps/apple/artifacts/backup-sync-validation/README.md`.

iCloud synchronization uses silent CloudKit notifications and the device's Apple Account. Agent alerts use the separate Oblien push connection, which requires sign-in; backing up connections does not register a phone for those alerts. See `Notifications.md` for the sign-in reminder and registration recovery flow.

`ConnectionSyncLiveTests` is opt-in with `MINDWIRE_LIVE_ICLOUD=1`. It uses a fresh `MindwireSyncValidation…` zone and fictional connections, then deletes that zone. It never erases the app's real zone. The physical iPhone reached CloudKit, but its first record upload returned Apple's **Quota exceeded** error. The user deferred the real backup/restore check until iCloud space is available; it has not passed yet.
