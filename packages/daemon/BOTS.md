# Mindwire bots

`botsVersion: 4` adds per-bot notifications and the expanded vector avatar catalog. Version 3 adds reusable base-engine selection, native task delegation, and authenticated links across computers and cloud workspaces. Version 2 adds saved icons; version 1 adds profiles, scoped management, memory and knowledge.
The daemon registry owns profiles and chat membership. Native harnesses continue to own transcripts,
authentication and execution. Developer turns with no `botId` keep their existing behavior.

`POST /bots/ensure {agentId, projectId}` creates the default Mindwire profile and assigns ungrouped
chats in that General setup project to it. It does not migrate other projects. Repeating setup is
idempotent; changing the default AI connection changes the default profile for future chats while
existing chats retain their original agent/session. Profiles belong to projects on the connected computer and synchronize through workspace snapshots and deltas. The same profiles appear in General and Developer modes.

Each profile stores name, purpose, instructions, durable memory, document text, archive state and a
revision. `Chat.botId` assigns a conversation to one profile. Old-client renames and notification
changes preserve that membership. Bot edits require `expectedRevision`; stale edits return 409.
Archiving preserves conversations and knowledge. Mindwire itself cannot be archived or renamed.

## Conversational management

At the start of a bot turn, the supervisor resolves the saved profile and adds its context to the
native harness. Claude uses `--append-system-prompt`; Codex merges the native developer instructions
with the current profile using `developerInstructions`. On cold resumes, Codex versions affected by
upstream #19045 also need a native developer-message update: a bounded check of saved model context
skips unchanged profiles, and `thread/inject_items` applies changed context before the user turn.
The updated native baseline remains available after compaction. OpenCode uses a native synthetic context
part. Grok receives an additive ACP text block before each user prompt, including loaded and
resumed sessions. The native base prompt, tools, permissions, approvals, and streaming remain in charge.
Explicit user system-prompt overrides still work for advanced clients. Older Codex bot conversations
with a recognizable Mindwire base-prompt override restore the installed CLI's native model prompt
through its resume API; transcript files are never rewritten. If an older custom model's native
prompt cannot be resolved, the runtime asks for a new conversation instead of guessing a prompt.
The default Mindwire profile knows the app's General experience, connected-computer model, flat
bot list, knowledge and management tools. It creates profiles from conversation and can investigate
user feedback by reading a bot's settings and a bounded excerpt of its recent conversations before
updating the relevant instructions or memory. A change applies on the next turn. Running turns keep
their original profile context.

The private `mindwire_bots` MCP server exposes these tools to Mindwire:

- `bots_list`, `bots_get`, `bots_create`, `bots_update`
- `bots_chats`, `bots_read_chat`, `bots_create_chat`
- `knowledge_search`, `knowledge_read`, `knowledge_put`, `knowledge_remove`
- `memory_read`, `memory_update`

Individual bots receive only knowledge search/read and memory read/update for their own profile.
The server rechecks identity, scope and archive state on every call. Tool visibility and scope do
not create a filesystem sandbox: native computer tools retain the connection's existing permissions.

Claude Code and Codex receive a per-turn MCP overlay, preserving other servers. OpenCode
uses `mindwired --bot-tool` through its native command tool. Both paths
reach the same handlers. A private loopback endpoint and run token expire with the run; the daemon
owner credential never enters this channel. Live externally owned terminal sessions must finish
before Mindwire can apply a bot's saved startup instructions and tools.

Successful mutations return `mindwireBot` structured results with the saved ID, name, operation and
revision. General renders a compact acknowledgement and Open action, then refreshes registry state.
Agent prose alone cannot create a profile. A retry of the same creation/name/configuration reuses
the existing bot; chat creation supports a stable request ID.

## Knowledge and memory

Memory is editable durable text, separate from both instructions and conversation messages. An edit
to one field preserves the rest. Knowledge sources have stable IDs, titles and saved text. Mindwire
can extract user-provided documents with its native file tools, then save text or a grounded summary
using `knowledge_put`. Search returns ranked lexical passages; read supports Unicode-safe paging.
There is no separate transcript copy or automatic sharing of one bot's conversations with another.

Limits: 120-byte names, 2 KiB purposes, 32 KiB instructions, 16 KiB memory, 32 knowledge sources,
64 KiB per source and 256 KiB total source text per bot. Larger documents should be split or
summarized. Bot chat inspection returns at most 12 recent messages with bounded text excerpts.

## Owner API and clients

- `GET/POST /bots`, `POST /bots/ensure`
- `GET/PATCH /bots/{id}`
- `GET/POST /bots/{id}/chats`

Owner HTTP calls use the existing daemon authentication. TypeScript exposes `client.bots`; Go exposes
`client.Bots`. The Apple app caches records, restores bot/chat navigation, and shares its flat bot
list and creation flow across General and Developer modes. Conversational creation/editing is
available through Mindwire. The version 3 engine selection, delegation and peer tools require
`botsVersion >= 3`.

## Bot appearance

The optional `icon` field persists a color-character template and synchronizes in bot snapshots.
Colors: `mint`, `amber`, `lilac`, `blue`, `peach`, `rose`, `olive`, `cyan`, `coral`, `periwinkle`.
Characters: `pebble`, `squircle`, `sprout`, `bean`, `bloom`, `spark`, `drop`, `arch`, `orbit`,
`comet`, `cloud`, `clover`, `flame`, `moon`, `fox`, `cat`, `ghost`, `robot`, `jelly`, `leaf`,
`mushroom`, `diamond`, `crystal`, `heart`. For example, `peach-fox`. Omitted fields preserve
the saved icon; an empty string resets to automatic. Unknown templates fail validation before any
record change. Both the owner API and Mindwire's create/update tools accept icons. Old profiles and
clients continue to work. Legacy templates require `botsVersion >= 2`; expanded templates require
`botsVersion >= 4`. Existing automatic selections keep their original seed mapping. New agents
save an explicit icon from the full catalog. Chats, lists, settings and push use one vector renderer.

## Notification preferences (version 4)

`PATCH /bots/{id}` accepts `notificationsMuted` with `expectedRevision`. A bot chat is muted when
it or its bot is muted. A base engine's preference only applies to unassigned Developer chats.
Schema 9 copies each old engine preference into its existing bots once, preserving saved choices;
new bots start unmuted. Changes synchronize with ordinary workspace snapshots/deltas. Clients must
check both `botsVersion >= 4` and `notificationPreferencesVersion >= 2` before editing this field.

## Named bots and delegation (version 3)

`botsVersion: 3` enables the same named bot model in General and Developer modes.
A bot chooses an existing `agentId` (base engine/authentication) and `projectId`
(work directory); several bots can reuse one connection. Creating a bot requires
only those parents and a name. Instructions, purpose, memory and documents may be
empty, and no General master needs to exist in a Developer project first. Existing
native chats are preserved and are not reassigned when a bot is created.

Engine `capabilities.botProfiles` and catalog `botProfiles` explicitly declare
support for refreshing saved instructions and scoped tools on every resumed turn.
Codex, Claude Code, OpenCode and Grok support bots. Grok's session-only system prompt and MCP
overrides retain their native restrictions; saved bot context instead travels on every ACP
prompt, with the same scoped native-command tool bridge used by OpenCode. Older services
that report an unsupported engine remain gated until updated. Owner HTTP, embedded SDK and native management tools use
the same registry admission; `bots_agents` returns only bot-capable connections.

Mindwire masters can list and manage bots across **all projects on this daemon**.
Child bots receive only their own memory and knowledge tools. The daemon resolves
identity from its actual chat on every run and rechecks saved membership/archive
state on every tool call. `bots_agents` lists reusable profiles and projects;
`bots_create` accepts optional `agentId` and `projectId` instead of forcing the
master's engine. Omitted parents retain the master's current defaults.

The new native tools are `bots_delegate`, `bots_tasks`, `bots_task`,
`bots_task_input` and `bots_task_cancel`. They use the same handlers as the owner
HTTP endpoints:

- `GET /bots/agents` → `{agents, projects}`.
- `GET /bots/{id}/tasks` → latest native run per chat, up to 50.
- `POST /bots/{id}/tasks` with `{requestId, message, chatId?, title?}`.
- `GET /bots/{id}/tasks/{runId}` → status, bounded current output/tool activity,
  pending interactions and recent native messages.
- `POST /bots/{id}/tasks/{runId}/input` with `{requestId, message}`.
- `POST /bots/{id}/tasks/{runId}/cancel` → `cancelRequested` acknowledgement.

Task responses contain `{botId, chatId, run}`. `run` is the ordinary durable native
run, with the same SSE/snapshot/history endpoints and notifications as a user
send. No second transcript, harness process manager or polling worker exists.
Starting a task returns 202 immediately; it does not claim completion. Every
request requires a stable ID, scoped to caller and bot and committed using the
native turn receipt. Repeating the same request returns its run; changed content
conflicts. Empty `chatId` creates one stable task conversation, while explicit
`chatId` must belong to the target bot. Input uses the native durable queue and
fails clearly when the engine does not support steering. Cancel does not delete
memory or conversation history.

A master cannot delegate to itself or another master. Children have no delegation
capability, preventing delegation cycles. At most four delegated tasks run on a
daemon and at most one delegated task per bot; existing one-turn-per-chat admission
still applies. Task execution retains the chosen engine's authentication,
permissions, native-session ownership, service-update checks and work-directory
validation. Management tools never answer approval prompts, change permission
modes or export credentials. The user answers approvals in the target bot's chat.

## Linked computers and cloud workspaces

Version 3 also lets a master use the same native tools across explicitly linked
computers. `bots_list` and `bots_agents` aggregate local records and linked peers
with a `workspaceId` on each result. Discovery keeps local results when a computer
is offline and reports that peer's error separately. All management, knowledge,
memory and task tools accept `workspaceId`; omitting it addresses this computer
(except discovery, which aggregates). The model never receives connection keys,
owner API credentials or phone SSH credentials. Remote mutation receipts include
`mindwireBot.workspaceId` so clients open the correct computer's bot/chat.

The authenticated owner provisions the graph using:

- `GET /bots/peers/identity` → `{workspaceId, publicKey, hostKeyFingerprint,
  port?, sshPort?, routes?}`. Only public identity material is returned.
- `POST /bots/peers/listener {port?}` → starts a peer-only SSH-over-WebSocket
  carrier and a raw SSH carrier on dedicated ports; returns the updated identity.
  Omit the port to allocate free ports. These bindings survive daemon restart.
- `GET /bots/peers` → public descriptors.
- `PUT /bots/peers/{workspaceId}` with `{name, publicKey, hostKeyFingerprint,
  routes, enabled?}` → stores a link and reciprocal incoming-key authorization.
  `enabled` defaults to true. Routes are `{kind:"ssh", host, port}` or
  `{kind:"websocket", url:"wss://…/ssh"}`. Up to 32 links / 8 routes per link.
- `DELETE /bots/peers/{workspaceId}` → revokes the link.

The phone exchanges only public identities and routes over its existing owner
connections. It registers both directions; that lets either master manage the
other computer. Paired computers reuse their existing pinned SSH carrier and
current routes. Cloud workspaces expose only the dedicated WebSocket port through
their existing port-exposure service. Raw SSH hosts may use the dedicated `sshPort`
when reachable. A blocked firewall or missing public route is reported as offline;
registering a route alone is not proof that it is reachable.

Every connection verifies the remote host fingerprint and authenticates using a
separate daemon-owned Ed25519 peer key. Keys and peer grants persist in the private
daemon state; none are copied from phone pairing. The only admitted SSH channel is
`mindwire-bots`, which calls the same scoped bot handlers as the local MCP server.
Peers cannot open a shell, forward arbitrary ports, access owner HTTP, pair devices,
respond to approvals or read credentials. Key rotation/revocation is checked for
every operation/channel. Peer calls are strictly one hop: a linked computer cannot
inherit access to the destination's other links. Delegation to any master remains
prohibited, preventing cross-computer delegation cycles. Task execution lives on
the destination daemon and continues after the master disconnects; stable task
receipts make transport retries safe.
Peer calls also reserve the same service-operation admission as owner HTTP, so an
idle runtime update cannot race a remote bot mutation.

Discovery fans out to at most four peers at once with a bounded deadline. There is
no background transcript sync or per-bot polling process. The owner app refreshes
public routes after reconnect and can revoke obsolete links. Existing phone SSH,
computer recovery, tunnel encryption and native chat streaming remain the source
of truth for their normal connections.

`POST /bots/peers/{workspaceId}/check {}` performs a bounded, read-only bot discovery
request and returns `{workspaceId, reachable, error?, addressRecovery?}`. Registering
keys remains distinct from verified reachability. The app can check after enrolling
both directions; no periodic bot execution or transcript polling is involved.

For computers already using encrypted address recovery, authorized daemon peer keys
are additional **directory readers**, separate from phone Devices. They never become
approved phones. The existing publisher encrypts its current routes for each reader
and withdraws revoked readers. A successful peer SSH response privately supplies that
peer's address-read grant; it is saved only in the daemon's private state, excluded
from owner peer descriptors, SDK identity responses and model tool results. The phone
never handles this secret or copies a phone directory credential.

After a saved route fails before any task request is transmitted, the daemon can
resolve a new address without the phone running. It signs lookup using its own peer
key, verifies the computer's pinned signature, audience, computer/registry/reader IDs,
expiration and monotonically increasing revision, and decrypts the AES-GCM record.
The anti-rollback watermark is persisted before reconnect; learned public routes are
saved only after a pinned SSH handshake. A failed or ambiguous write response never
triggers automatic write replay through address recovery.

Recovery requires one successful peer connection to learn the grant, enabled and
enrolled computer discovery, a functioning directory, and a current publication from
the target computer. Directory readers share its 64-reader limit; approved phones
retain priority, and a peer without capacity does not receive a recovery grant.
A successful authenticated response without a grant withdraws previously saved recovery.
It does not make an offline computer reachable, open a firewall,
or silently enable hosted discovery. Cloud peer port URLs use their existing stable
exposed-port routing; replacing/removing that exposure requires provisioning a new
route. Hosts with neither discovery nor stable reachable routes still need their
address updated through the app. These failures remain explicit per-computer errors.
