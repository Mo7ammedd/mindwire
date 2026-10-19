# General-mode Apps

Apps are saved destinations, separate from bot profiles and chat history. General mode exposes one Apps entry in the existing sidebar. Each tile shows an icon and name; opening it ensures its service is ready and displays its link in the shared web preview. A reminder without a web page opens its notification and schedule settings instead.

The daemon owns the records in the existing workspace SQLite registry. Apple stores only the same snapshot/delta cache used by bots and projects. Apps belong to a project and retain their owning computer identity; changing the default computer does not relocate existing apps. The Apple client creates the App builder as an ordinary bot through the existing profile API, using the existing AI connection, native tools and transcripts. Its ID and consumer instructions live in AssistantBotPresets.swift; the registry has no App builder role or automatic consumer presets. Existing user-edited instructions and memory are retained. The main Mindwire assistant can delegate through the existing authenticated bot bridge, including linked computers.

## Native tools

- `apps_list` / `apps_get`: discover saved apps and read their current revision. Mindwire aggregates linked computers; subsequent remote operations need the returned `workspaceId`.
- `apps_register`: save `projectId`, `name`, `icon` and `url`. Icons use SF Symbols or existing bot vectors. Registration does not execute anything. The same project and URL produce the same ID. A reminder uses `automation: true`, an empty URL and a name; its ID derives from the project and name.
- `apps_update`: compare-and-swap edits with `expectedRevision`. Removing sets `archived: true`, revokes backend notification access and pauses future schedules; files and running services remain intact.
- `apps_channels`: list enabled existing notification channel IDs, labels and types, without provider credentials.
- `apps_notifications_setup`: bind destinations and create/reuse a protected backend credential file. Only its path is returned. `rotate: true` revokes previous grants only after publishing a working replacement.
- `apps_schedules` / `apps_schedule_save` / `apps_schedule_delete`: inspect, create, update, pause or remove durable background work. Updates require its ID and revision. Active runs must finish before editing or deleting their schedule.

Ordinary bots manage their own apps. The App builder has the same ownership permissions as any ordinary bot; manager bots can manage apps across authorized computers. A familiar name, icon, ID or prompt grants no extra permission. No additional AI authentication or provider credential store is introduced.

## Opening an app

A local URL uses `http://127.0.0.1:PORT/path` (also localhost or ::1). The optional `healthPath` stays on that server. The daemon checks readiness, runs an idempotent `startupCommand` in the app project if unavailable, then checks readiness again. Scripts have 20 seconds to return; the full open operation has a 35 second limit. A service manager or detached process must own any long-running server. Concurrent open requests share one startup operation.

The phone reuses the computer connection and SSH port-forward infrastructure. Mindwire Cloud obtains a pinned temporary SSH grant; Mac opens its own local app directly. Public links without a startup script need no remote startup or tunnel. The shared WebKit preview allows user-chosen HTTP origins using [NSAllowsArbitraryLoadsInWebContent](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloadsinwebcontent); API URLSession traffic retains its existing ATS policy. No public port is opened. App startup does not hold the shared workspace metadata queue while waiting for readiness.

## Backend notifications

Setup writes a mode-0600 JSON file outside the project with `appId`, `endpoint` and `token`. Backend code reads this file at send time, then sends:

```http
POST <endpoint>
Authorization: Bearer <token>
Content-Type: application/json

{"eventId":"stable-id-for-this-event","title":"Ready","body":"Your report is ready."}
```

Never put this token in frontend code, a URL, a chat or source control. Only token hashes are stored in SQLite. A replacement grant is prepared before publishing the credential file; prior grants are retired after publication and configuration succeed. Failed file writes discard only the replacement, preserving the working credential. Startup reconciles an interrupted rotation from the atomically published file. The token can only send as its one app through its saved destinations; the endpoint accepts loopback requests without a browser Origin. It cannot read workspace data or choose recipients. The owner daemon token is not accepted at this endpoint. File endpoints are refreshed after a daemon address change, so backend code must reread the file rather than caching it at startup.

Delivery reuses the existing notification channels and phone registration. Push carries the saved app name/icon and deep-links to the app. Each app has a mute and destination settings. Retry a failed send with the same `eventId`: receipts suppress destinations that already accepted it (the latest 1000 completed receipts per app are retained). Delivery has a per-app rate limit; a lost provider acknowledgement can still result in a duplicate notification.

## Schedules

A schedule has a name, a command and/or notification message, plus one of:

- `runAt`: a one-time timestamp with UTC or an explicit offset.
- `intervalSeconds`: an interval of at least 60 seconds, optionally with a first `runAt`.
- `localTime` and IANA `timeZone`, optionally `weekdays` (Sunday=0): calendar recurrence.

Agent-created schedules containing an active command require an explicit owner approval through the existing supervisor interaction, transcript, push and response path. Notification-only reminders and pausing do not require shell approval. Authenticated owner API/SDK calls explicitly authorize their commands; peer daemons relay approved agent operations over their existing authenticated link. These commands run with the host OS user’s permissions; a project directory is not a sandbox. Commands run in the owning project for at most 30 seconds. An optional notification is sent after success. The long-lived daemon explicitly starts one scheduler for all app jobs. Constructing the HTTP API or Go SDK alone starts no scheduler. Embedded hosts opt in with Go `Options.RunScheduledJobs`; `WithAgent` views share the same owner. The scheduler sleeps until work or configuration changes and limits concurrent workers. SQLite claims prevent concurrent duplicate runs. Saved outcomes and next run times are visible in app settings. Notification failures back off and retry without rerunning a completed command. After an interrupted run, notification-only work can recover; an uncertain command is recorded as interrupted rather than blindly replayed. Repeated occurrences missed while offline are coalesced into one catch-up, then the next future occurrence is scheduled.

Scheduling survives phone, chat and daemon restarts, but the computer must be awake and Mindwire running. Always-on work belongs on an always-on cloud computer. Notification permission and existing delivery configuration must be enabled first. This does not create an OS wake alarm or another AI turn.

The feature is advertised by `health.appsVersion >= 1`. The authenticated `/apps` HTTP API, native tools and Go/TypeScript clients share the same registry and execution service. Older daemons keep normal chat working and show an update message for Apps actions.

## SDK boundary

Go exposes application resources, readiness, scheduling and scoped notifications independently of any General/Developer UI mode. Core bot instructions describe tools, ownership and permissions; consumer prompts are saved profile data supplied by the client. Caller-provided turn context is preserved. The Apple app owns the Apps catalog, the App builder preset and General-mode instructions.

`client.Bots.Update(id, BotEdit{AgentID: &agentID, ExpectedRevision: revision})` chooses an engine for future chats without moving existing transcripts or authentication. Native changes require `botsVersion >= 5`. Profile knowledge and memory remain intact.

## Workflow skills

With `botsVersion >= 6`, General-mode presets keep a short mindset in profile
instructions and assign two portable skill documents: `mindwire-apps` and
`mindwire-automations`. Their only authored copies are the Apple client's
`Resources/BotSkills/*/SKILL.md` files. The client saves them through the ordinary
bot profile API; Go contains no consumer workflow definitions.

Go validates and stores `Bot.skills` independently of instructions, memory and
knowledge. During a bot turn it prepares a temporary, private skill bundle. Codex
loads it through the app server's process-scoped extra roots; Claude uses a
session-only plugin directory. The existing scoped tool bridge exposes
`skills_list` and `skills_read` for the same documents on other harnesses and
older Codex versions. The initial context carries metadata, not workflow bodies.
The bundle is removed when its turn ends. Neither the user's repository nor
global harness configuration is modified, and skills do not grant permissions.
The portable format rejects native permission/hook frontmatter and dynamic shell
substitutions; actual commands continue through the harness's existing tools.

An exact fingerprint identifies the previously shipped default instructions for
migration. User-edited instructions, memory, knowledge and explicit skill
assignments remain intact. Older daemons receive an inline compatibility form
generated from these same documents; once skill support is available, that exact
generated form migrates to the short profile and assigned skills. There is no
separate workflow implementation per harness. Native sessions already owned by
another process retain the existing ownership restrictions.


## Public sharing

Apps keeps the original private `url` and a separate confirmed `publicUrl`. Copy Link prefers the public URL and otherwise copies the saved private URL, never a temporary SSH listener. Catalog and settings actions and native `apps_request_publish` cards all use one Publish sheet.

`health.appsVersion >= 2` adds `staticDirectory`, `publicUrl` and `POST /apps/{id}/publication/prepare`. Preparation validates the active app and project. Port plans use the saved loopback destination. Static plans require a dedicated project subfolder with index.html, regular public files, no symbolic links or private files, and limits of 100 MB / 10000 entries. Go returns a hosting plan; it never holds provider/account credentials or performs subscription checkout. Go and TypeScript SDKs expose the same preparation operation.

On a Cloud computer, the client ensures readiness and reuses or exposes the app port through the existing public-access API. Static output uses the computer-scoped Mindwire Pages gateway, which verifies account/computer ownership and provider namespace and uses a stable per-app page identity for retries and redeploys. Both operations are explicit owner actions. A separate authenticated CAS update records the link after provider success; conflicts retry the record update without redeploying.

For a local/SSH computer, Publish opens the existing Mindwire Cloud subscription flow. Creating a cloud computer does not move a local project: App builder must build or migrate there before requesting publishing on the cloud-owned app. An action-card receipt is not proof of deployment; agents check apps_get.publicUrl. The canonical app-building skill explains both hosting methods and this handoff. Exact older bundled skills upgrade while custom skill documents remain intact.

General chat presents tool activity as compact wrapping steps with the chat's activity color. Native bot/app action cards stay actionable. Developer chat retains the original command disclosures, output and file diffs. The same saved transcript and virtualized renderer serve both modes.
