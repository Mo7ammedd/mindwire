# Mindwire mobile experience proposal

Saved from the product discussion on October 15, 2026. General / Developer modes and guided
mobile setup were approved and implemented on October 16. The desktop interface remains deferred.

Mindwire should open into a personal assistant chat, with optional Developer tools exposing the
existing coding interface. Both experiences use the same Mindwire agent, conversations, execution
services, and connections. Supported subscriptions power the agent through the underlying harnesses.

## First use

1. Fresh installs choose General or Developer. Existing installations keep Developer mode.
2. General setup asks which computer to use, with Your computer and Cloud computer as simple,
   outlined choices. Explain the existing files/apps, the need to keep a personal computer on, and
   separate cloud billing. Saved personal computers and pairing live under Your computer. Cloud sign-in
   and saved cloud computers appear only under Cloud computer; prices and provisioning load after Create.
   Back from AI choice returns to that same destination. Keep action titles and instructions short.
   Existing pairing and cloud services own these operations.
3. Offer Continue with Claude and Continue with ChatGPT directly. Other ways to connect contains
   provider API keys and xAI. Reuse an available profile, then verify readiness and open the matching
   live authentication method once. The selected computer and profile survive interrupted setup;
   Back returns to account choice without discarding the computer. Harness names remain in Developer
   mode. Authentication protocols, credential storage and installation jobs stay shared.
4. After authentication, prepare `~/.mindwire-workspace` on that computer and register it through
   the shared project API. Repeated setup reuses its directory and project; no existing files move.
   This is a working directory, not an OS permission boundary or a sandbox.
5. Start chatting with Mindwire using the existing ChatScreen and composer. General history groups
   chats under collapsible bots. Mindwire creates and improves bots through conversation, using
   daemon-owned tools for their purpose, instructions, memory and knowledge. The scrolling sidebar
   header keeps Search and + together; its menu contains Create a bot, Settings and Account.
   Chat state, drafts, transcript rendering and native drawer gestures remain shared.

AI access and computer access are separate connections. Connecting a subscription alone does not
provide a computer on which the agent can execute tasks.

## Everyday interface

Keep chat and conversation history central. Show readable progress, approvals, and useful results:
documents, files, previews, and completed actions. A small connection indicator identifies the
computer doing the work. Detailed tool output remains available when needed.

Users should not have to create named agents, understand harnesses, or configure SSH to begin an
ordinary task. The runtime can retain its existing workspace and agent structure underneath.

## Developer tools

Settings → App mode switches between General and Developer. Developer retains the entire existing
Projects / Agents / Workspaces / Settings interface. General retains attachments, voice, file
access and downloads, with the coding-specific controls in Developer mode.

Changing this setting changes navigation and visible tools. Conversations, drafts, credentials,
connections, and active work remain shared. Reuse the existing chat state, transcript cache,
connection lifecycle, and reconnection logic. Developer screens fetch their data when opened.

## Subscription setup and free access

Present Connect your subscription and, when a real offering is available, Try Mindwire. A free
offering needs an explicit implementation and limits, such as a funded trial or supported local
models. It is not another identity provider.

Begin with the supported native sign-in flows belonging to each installed harness. Evaluate any
new direct provider integration separately. Anthropic distinguishes users signing into unmodified
Claude Code from third-party apps offering their own Claude.ai login. OpenAI's direct ChatGPT plan
sharing documentation also distinguishes local and open-source integrations from paid or remotely
hosted offerings.

- [Claude Code authentication and platform guidance](https://code.claude.com/docs/en/legal-and-compliance)
- [OpenAI ChatGPT plan sharing documentation](https://developers.openai.com/siwc/token-sharing-open-source)

## Current implementation and next work

The mobile shell, mode choice, guided setup and shared chat presentation are implemented. Each
window restores its General conversation independently of Developer navigation. Changing the
default computer/profile affects new conversations; existing chats keep their original context.
Cloud setup uses a default configuration and requires a live credit estimate, balance and quota
before enabling creation. It keeps the existing Oblien login and provisioning implementation.

General onboarding, computer choice, pairing, AI selection and cloud review now use shared designed
pages instead of settings-style forms. Setup uses one navigation stack; the existing chat, composer,
tools and session state are unchanged. Developer setup retains its original presentation.

The intended computer journey is download Mindwire on the computer, open its pairing code, and
scan it with the phone. The mobile flow reuses the existing QR scanner and pairing operation.
A desktop-app installer has not been published in the checked releases. Until a real
`MINDWIRE_DESKTOP_DOWNLOAD_URL` is supplied, General shows `mindwire connect pair` for computers
already using the terminal app. The terminal dashboard puts **Show QR code** first, including
when phones are already paired. A graphical companion installer and pairing-code
display, a funded free offering, and further activity/result presentation remain follow-up work.
No new provider authentication mechanism was added.

Desktop now starts on **This Mac**. It adopts the existing local runtime or starts the bundled
helper, prepares `~/.mindwire-workspace`, and reuses an available AI account. Account setup appears
inline only when needed. Remote computers and cloud workspaces are additional destinations.
The desktop messenger uses a persistent rounded bot sidebar and the shared transcript, composer,
drafts and session lifecycle. It restores the current conversation instead of creating one at launch.

General and Developer share named bots with a selected base engine, optional instructions,
memory and knowledge. The master can manage and delegate across authenticated computer links.
Codex, Claude Code and OpenCode support reusable bots; the daemon advertises this explicitly.
Grok remains available for ordinary Developer chats because its native protocol cannot refresh
saved bot instructions on resumed conversations. iPhone installation is outside the current scope.

The computer companion's setup is part of the consumer experience. Simplifying the mobile screens
alone will not make terminal-based installation accessible to ordinary users.

## Decisions to revisit

- The companion installation experience.
- Supported subscription connections and provider eligibility.
- Whether and how to offer free use, including inference and compute limits.
