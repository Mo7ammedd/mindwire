# Conversation loading and keyboard

Reviewed on 6 October 2026 with Xcode 26.5, using the production chat screens and offline demo data.

| Screen | iPhone 17 Pro Max | iPad Pro 13-inch (M5), landscape |
| --- | --- | --- |
| Codex loading, dark | [Screenshot](iphone-codex-dark.png) | [Screenshot](ipad-codex-dark.png) |
| Claude loading, light | [Screenshot](iphone-claude-light.png) | [Screenshot](ipad-claude-light.png) |
| Keyboard dismissed, draft preserved, commands expanded | [Screenshot](iphone-keyboard-dismissed.png) | [Screenshot](ipad-keyboard-dismissed.png) |

The three `ChatComposerInteractionTests` scenarios passed on both simulators: dismissing during delayed history loading, dismissing in an empty conversation, and dismissing from loaded text or blank transcript space. Tapping within the composer retains focus. The native command disclosure still expands on the same tap that dismisses the keyboard, and the draft remains intact.

The nine `ChatFeedTests` checks also passed, covering recycled rows, scroll restoration, live output, pagination, and reopening cached conversations.

The loading view uses the existing harness artwork inside a small progress ring. Its animation is confined to the loading glyph and pauses with Reduce Motion. Keyboard dismissal acts on the conversation's native window and excludes the composer and presented sheets.

Run `MindwireUITests/ChatComposerInteractionTests` with the `Mindwire` scheme. The tests select the `chat-loading` fixture and delay its offline history response; they do not require a live agent or workspace.
