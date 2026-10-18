// Package notify is the delivery layer for agent notifications. The daemon is a dumb, provider-
// agnostic EMITTER: it POSTs an agent.Notification to a webhook URL the client provisioned via
// PUT /notify/config. Where that webhook points — a serverless function, a Slack/ntfy relay, a
// push gateway (APNs/FCM), your own backend — is entirely up to you; the daemon holds no device
// tokens or push credentials. With no webhook configured, notifications are a silent no-op.
package notify

import (
	"context"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

// Notifier delivers a Notification. Implementations: WebhookNotifier (the built-in HTTP emitter),
// Stream (local SSE broadcaster), and Noop (disabled).
type Notifier interface {
	Notify(ctx context.Context, n agent.Notification) error
}

// Preferences is consulted immediately before delivery, across all notification
// transports and conditions. Implemented by the authoritative workspace registry.
type Preferences interface {
	NotificationsMuted(chatID string) (bool, error)
}

// BotIdentity is the saved sender, independent of the engine used by a turn.
type BotIdentity struct {
	ID, Name, Icon, WorkspaceID string
}

// IdentityResolver is optional for legacy notification sources.
type IdentityResolver interface {
	NotificationIdentity(chatID string) (BotIdentity, error)
}

// Noop drops notifications (used in tests / when delivery is intentionally off).
type Noop struct{}

func (Noop) Notify(context.Context, agent.Notification) error { return nil }
