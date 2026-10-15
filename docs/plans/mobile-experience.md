# Mindwire mobile experience proposal

Saved from the product discussion on October 15, 2026. This is a draft direction to revisit;
implementation has not been approved or started.

Mindwire should open into a personal assistant chat, with optional Developer tools exposing the
existing coding interface. Both experiences use the same Mindwire agent, conversations, execution
services, and connections. Supported subscriptions power the agent through the underlying harnesses.

## First use

1. Open into a composer with concrete examples such as organizing files, researching a topic,
   creating a document, or automating a repetitive task.
2. Preserve the first request while guiding the user through any required setup.
3. Connect the computer where work will happen. Start with My computer; offer Mindwire Cloud
   when its managed setup and account flow are ready.
4. Detect existing authenticated agent installations before asking the user to connect AI access.
5. Once the computer and AI connection are verified, return to the chat and submit the task once.

AI access and computer access are separate connections. Connecting a subscription alone does not
provide a computer on which the agent can execute tasks.

## Everyday interface

Keep chat and conversation history central. Show readable progress, approvals, and useful results:
documents, files, previews, and completed actions. A small connection indicator identifies the
computer doing the work. Detailed tool output remains available when needed.

Users should not have to create named agents, understand harnesses, or configure SSH to begin an
ordinary task. The runtime can retain its existing workspace and agent structure underneath.

## Developer tools

A setting exposes projects, Git, the terminal, file browser, port forwarding, and advanced agent
configuration. Existing users retain access to their current interface during migration.

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

## Suggested delivery order

First build the chat home, guided connection setup, and Developer tools setting while preserving
the current runtime and chat behavior. Then make computer setup install, open, and scan a QR code.
Add managed cloud onboarding and a free offering after their infrastructure and economics are ready.

The computer companion's setup is part of the consumer experience. Simplifying the mobile screens
alone will not make terminal-based installation accessible to ordinary users.

## Decisions to revisit

- The final navigation and name of the Developer tools setting.
- The default runtime location and companion installation experience.
- Supported subscription connections and provider eligibility.
- Whether and how to offer free use, including inference and compute limits.
- The timing and account requirements of Mindwire Cloud.
