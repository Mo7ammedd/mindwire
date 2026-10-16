# Mindwire mobile experience proposal

Saved from the product discussion on October 15, 2026. General / Developer modes and guided
mobile setup were approved and implemented on October 16. The desktop interface remains deferred.

Mindwire should open into a personal assistant chat, with optional Developer tools exposing the
existing coding interface. Both experiences use the same Mindwire agent, conversations, execution
services, and connections. Supported subscriptions power the agent through the underlying harnesses.

## First use

1. Fresh installs choose General or Developer. Existing installations keep Developer mode.
2. General setup explains why Mindwire needs a computer, then offers My computer, Mindwire Cloud,
   and already connected computers. Existing pairing and cloud services own these operations.
3. Reuse an available AI connection or connect supported AI access through the shared installation
   and authentication screens. The selected computer and profile survive interrupted setup.
4. After authentication, prepare `~/.mindwire-workspace` on that computer and register it through
   the shared project API. Repeated setup reuses its directory and project; no existing files move.
   This is a working directory, not an OS permission boundary or a sandbox.
5. Start chatting using the existing ChatScreen and composer. History is a flat, searchable list.

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

Computer pairing still uses the current CLI installation and QR flow. A graphical companion
installer, a funded free offering, and further consumer-friendly activity/result presentation are
separate follow-up work. No new provider authentication mechanism was added.

The computer companion's setup is part of the consumer experience. Simplifying the mobile screens
alone will not make terminal-based installation accessible to ordinary users.

## Decisions to revisit

- The companion installation experience.
- Supported subscription connections and provider eligibility.
- Whether and how to offer free use, including inference and compute limits.
