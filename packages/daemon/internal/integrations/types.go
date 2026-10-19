// Package integrations connects external messaging transports to the existing bot
// runtime. It owns delivery receipts and routing, never a second agent or transcript.
package integrations

import (
	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

const Version = 1

type Credentials struct {
	BotToken      string `json:"botToken,omitempty"`
	SigningSecret string `json:"signingSecret,omitempty"`
	WebhookSecret string `json:"webhookSecret,omitempty"`
	PublicKey     string `json:"publicKey,omitempty"`
	ClientSecret  string `json:"clientSecret,omitempty"`
}

// Spec is a complete configuration. Credentials are write-only; omitted fields
// preserve existing credentials on update. Revision prevents concurrent overwrites.
type Spec struct {
	Name             string            `json:"name"`
	Provider         string            `json:"provider"`
	BotID            string            `json:"botId"`
	Mode             string            `json:"mode"`
	Enabled          bool              `json:"enabled"`
	ChannelIDs       []string          `json:"channelIds"`
	UserIDs          []string          `json:"userIds,omitempty"`
	WorkspaceID      string            `json:"workspaceId,omitempty"` // Slack team, Discord guild, Teams tenant
	ApplicationID    string            `json:"applicationId,omitempty"`
	Command          string            `json:"command,omitempty"`
	Notify           bool              `json:"notify"`
	Conditions       []agent.Condition `json:"conditions,omitempty"`
	Destination      string            `json:"destination,omitempty"`
	ServiceURL       string            `json:"serviceUrl,omitempty"` // Teams connector, owner-configured
	ExpectedRevision int64             `json:"expectedRevision,omitempty"`
	Credentials      *Credentials      `json:"credentials,omitempty"`
}

type Connection struct {
	ID       string `json:"id"`
	Revision int64  `json:"revision"`
	Spec
	HasCredentials bool   `json:"hasCredentials"`
	WebhookPath    string `json:"webhookPath"`
}

type savedConnection struct {
	Connection
	Secrets Credentials `json:"secrets"`
}

type Receipt struct {
	ID            string `json:"id"`
	IntegrationID string `json:"integrationId"`
	ChannelID     string `json:"channelId"`
	UserID        string `json:"userId"`
	State         string `json:"state"`
	ChatID        string `json:"chatId,omitempty"`
	RunID         string `json:"runId,omitempty"`
	Error         string `json:"error,omitempty"`
	CreatedAt     string `json:"createdAt"`
}

type envelope struct {
	Receipt
	Text             string `json:"text"`
	ThreadID         string `json:"threadId,omitempty"`
	Workspace        string `json:"workspace,omitempty"`
	Command          bool   `json:"command,omitempty"`
	InteractionToken string `json:"interactionToken,omitempty"`
	MessageID        string `json:"messageId,omitempty"`
	DeliveredText    string `json:"deliveredText,omitempty"`
}

type conversation struct {
	ChatID     string `json:"chatId"`
	RunID      string `json:"runId,omitempty"`
	Generation int    `json:"generation"`
}
