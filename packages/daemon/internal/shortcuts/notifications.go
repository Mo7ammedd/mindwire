package shortcuts

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/notify"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"github.com/oblien/mindwire/packages/daemon/internal/session"
)

type notificationBudget struct {
	count int
	until time.Time
}
type Channel struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Type string `json:"type"`
}
type NotificationMessage struct {
	EventID string `json:"eventId"`
	Title   string `json:"title,omitempty"`
	Body    string `json:"body,omitempty"`
}
type appCredential struct {
	AppID    string `json:"appId"`
	Endpoint string `json:"endpoint"`
	Token    string `json:"token"`
}

// Existing channel credentials remain in the existing session store. An app gets
// only a revocable capability for its own notification endpoint.
func (s *Service) ConfigureNotifications(store *session.Store) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.notifications != nil || s.closed {
		return
	}
	s.notifications = store
}

func (s *Service) SetAddress(address string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	if host != "localhost" && (net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback()) {
		// The backend capability is accepted only on the owner's local computer.
		host = "127.0.0.1"
	}
	s.mu.Lock()
	s.notifyBase = "http://" + net.JoinHostPort(host, port)
	s.mu.Unlock()
	// Preserve app credentials when the daemon's local API address changes.
	apps, err := s.db.Apps()
	if err != nil {
		return err
	}
	s.credentialMu.Lock()
	defer s.credentialMu.Unlock()
	for _, app := range apps {
		path := s.credentialPath(app.ID)
		data, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			continue
		}
		var credential appCredential
		if err = json.Unmarshal(data, &credential); err != nil {
			continue
		}
		if !s.db.CheckAppToken(app.ID, credential.Token) {
			continue
		}
		credential.Endpoint = s.endpoint(app.ID)
		if err = writeCredential(path, credential); err != nil {
			continue
		}
		// Reconcile an interrupted rotation using the atomically published file.
		if err = s.db.RetainAppToken(app.ID, credential.Token); err != nil {
			continue
		}
	}
	return nil
}

func (s *Service) endpoint(id string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.notifyBase == "" {
		return ""
	}
	return s.notifyBase + "/apps/" + url.PathEscape(id) + "/notify"
}
func (s *Service) credentialPath(id string) string {
	sum := sha256.Sum256([]byte(id))
	return filepath.Join(s.db.Directory(), "apps", hex.EncodeToString(sum[:16]), "notifications.json")
}
func writeCredential(path string, credential appCredential) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	raw, err := json.Marshal(credential)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".notifications-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(raw)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}

func (s *Service) Channels() []Channel {
	out := []Channel{}
	if s.integrationChannels != nil {
		out = append(out, s.integrationChannels.Channels()...)
	}
	if s.notifications == nil {
		return out
	}
	if target, _, _ := s.notifications.NotifyConfig(); target != "" {
		out = append(out, Channel{"mindwire", "Default", string(agent.ChannelPush)})
	}
	for _, channel := range s.notifications.NotifyChannels() {
		if channel.Enabled && channel.URL != "" {
			out = append(out, Channel{channel.ID, channel.Label, string(channel.Type)})
		}
	}
	return out
}

func (s *Service) NotificationSetup(id string, channelIDs []string, rotate bool) (registry.AppShortcut, string, error) {
	s.credentialMu.Lock()
	defer s.credentialMu.Unlock()
	app, err := s.db.App(id)
	if err != nil {
		return app, "", err
	}
	if app.Archived {
		return app, "", registry.ErrDeleted
	}
	if s.endpoint(id) == "" {
		return app, "", errors.New("app backend notification credentials require the running Mindwire daemon's HTTP endpoint")
	}
	if len(channelIDs) == 0 {
		channelIDs = app.ChannelIDs
	}
	if len(channelIDs) == 0 {
		channelIDs = []string{"mindwire"}
	}
	available := map[string]bool{}
	for _, channel := range s.Channels() {
		available[channel.ID] = true
	}
	for _, id := range channelIDs {
		if !available[id] {
			return app, "", errors.New("notification channel is unavailable; configure notification delivery or choose an available channel from apps_channels")
		}
	}
	if len(channelIDs) > 16 {
		return app, "", errors.New("choose at most 16 notification channels")
	}
	path := s.credentialPath(id)
	var credential appCredential
	if raw, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(raw, &credential)
	}
	prepared := rotate || !s.db.CheckAppToken(id, credential.Token)
	if prepared {
		credential = appCredential{AppID: id, Endpoint: s.endpoint(id), Token: "mwa_" + rand.Text() + rand.Text()}
		if err = s.db.AddAppToken(id, credential.Token); err != nil {
			return app, "", err
		}
	}
	credential.Endpoint = s.endpoint(id)
	if err = writeCredential(path, credential); err != nil {
		if prepared {
			err = errors.Join(err, s.db.DiscardAppToken(id, credential.Token))
		}
		return app, "", err
	}
	muted := false
	app, err = s.db.UpdateApp(id, registry.AppShortcutPatch{ExpectedRevision: app.Revision, ChannelIDs: &channelIDs, NotificationsMuted: &muted})
	if err != nil {
		return app, "", err
	}
	// Only now is rotation complete. A failed file publish never revokes the old
	// backend credential; interrupted publishes are reconciled on the next startup.
	if err = s.db.RetainAppToken(id, credential.Token); err != nil {
		return app, "", err
	}
	return app, path, nil
}

func (s *Service) AuthorizedNotification(id, token string) bool { return s.db.CheckAppToken(id, token) }
func (s *Service) RevokeNotifications(id string) error {
	s.credentialMu.Lock()
	defer s.credentialMu.Unlock()
	if err := s.db.RevokeAppToken(id); err != nil {
		return err
	}
	if err := os.Remove(s.credentialPath(id)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (s *Service) Notify(ctx context.Context, id string, message NotificationMessage) error {
	if strings.TrimSpace(message.EventID) == "" || len(message.EventID) > 160 || len(message.Title) > 256 || len(message.Body) > 2048 || (message.Title == "" && message.Body == "") {
		return fmt.Errorf("%w: eventId and a bounded title or body are required", registry.ErrInvalid)
	}
	app, err := s.db.App(id)
	if err != nil {
		return err
	}
	if app.Archived {
		return registry.ErrDeleted
	}
	if _, err := s.db.AppDirectory(app); err != nil {
		return err
	}
	if app.NotificationsMuted {
		return nil
	}
	s.mu.Lock()
	budget := s.budgets[id]
	if time.Now().After(budget.until) {
		budget = notificationBudget{until: time.Now().Add(time.Minute)}
	}
	budget.count++
	s.budgets[id] = budget
	s.mu.Unlock()
	if budget.count > 60 {
		return errors.New("this app has reached its notification rate limit; retry in one minute")
	}
	channels := app.ChannelIDs
	if len(channels) == 0 {
		channels = []string{"mindwire"}
	}
	if s.notifications == nil {
		return errors.New("notification delivery is unavailable")
	}
	var targets []agent.NotifyChannel
	for _, id := range channels {
		if id == "mindwire" {
			target, _, token := s.notifications.NotifyConfig()
			if target != "" {
				targets = append(targets, agent.NotifyChannel{ID: id, URL: target, Token: token, Enabled: true, Type: s.notifications.NotifyFormat()})
			}
		} else if strings.HasPrefix(id, "integration:") && s.integrationChannels != nil {
			for _, ch := range s.integrationChannels.Channels() {
				if ch.ID == id {
					targets = append(targets, agent.NotifyChannel{ID: id, Enabled: true})
				}
			}
		} else if channel, ok := s.notifications.NotifyChannel(id); ok && channel.Enabled {
			targets = append(targets, channel)
		}
	}
	if len(targets) == 0 {
		return errors.New("this app has no enabled notification channel")
	}
	if message.Title == "" {
		message.Title = app.Name
	}
	notification := agent.Notification{Condition: agent.Condition("app"), Title: message.Title, Body: message.Body, AppID: app.ID, AppName: app.Name, AppIcon: app.Icon, WorkspaceID: app.WorkspaceID, EventID: message.EventID}
	// Receipts are per destination: retrying a partial fan-out does not resend to
	// a destination which already accepted this event.
	var wg sync.WaitGroup
	var mu sync.Mutex
	var failures []error
	for _, channel := range targets {
		sum := sha256.Sum256([]byte(message.EventID + "\x00" + channel.ID))
		key := hex.EncodeToString(sum[:])
		claimed, err := s.db.ClaimAppNotification(id, key)
		if err != nil {
			mu.Lock()
			failures = append(failures, err)
			mu.Unlock()
			continue
		}
		if !claimed {
			continue
		}
		wg.Add(1)
		go func(channel agent.NotifyChannel, key string) {
			defer wg.Done()
			var err error
			if strings.HasPrefix(channel.ID, "integration:") && s.integrationChannels != nil {
				err = s.integrationChannels.Send(ctx, strings.TrimPrefix(channel.ID, "integration:"), strings.TrimSpace(notification.Title+"\n"+notification.Body))
			} else {
				err = notify.DeliverOne(ctx, s.deliveryHTTP, channel, notification)
			}
			recordErr := s.db.FinishAppNotification(id, key, err)
			if err != nil || recordErr != nil {
				mu.Lock()
				failures = append(failures, errors.New("notification delivery failed for "+channel.ID))
				mu.Unlock()
			}
		}(channel, key)
	}
	wg.Wait()
	return errors.Join(failures...)
}
