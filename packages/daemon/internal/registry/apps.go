package registry

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"time"
)

const AppsVersion = 2

// AppShortcut is a saved application destination, owned by its computer.
// The startup command is an optional, idempotent ensure script, never a new AI turn.
type AppShortcut struct {
	Record
	ProjectID          string   `json:"projectId"`
	BotID              string   `json:"botId,omitempty"`
	Name               string   `json:"name"`
	Icon               string   `json:"icon,omitempty"`
	URL                string   `json:"url"`
	StartupCommand     string   `json:"startupCommand,omitempty"`
	HealthPath         string   `json:"healthPath,omitempty"`
	Archived           bool     `json:"archived"`
	ChannelIDs         []string `json:"channelIds,omitempty"`
	NotificationsMuted bool     `json:"notificationsMuted"`
	Automation         bool     `json:"automation,omitempty"`
	StaticDirectory    string   `json:"staticDirectory,omitempty"`
	PublicURL          string   `json:"publicUrl,omitempty"`
}

type AppShortcutPatch struct {
	ExpectedRevision   int64     `json:"expectedRevision"`
	Name               *string   `json:"name,omitempty"`
	Icon               *string   `json:"icon,omitempty"`
	URL                *string   `json:"url,omitempty"`
	StartupCommand     *string   `json:"startupCommand,omitempty"`
	HealthPath         *string   `json:"healthPath,omitempty"`
	Archived           *bool     `json:"archived,omitempty"`
	ChannelIDs         *[]string `json:"channelIds,omitempty"`
	NotificationsMuted *bool     `json:"notificationsMuted,omitempty"`
	StaticDirectory    *string   `json:"staticDirectory,omitempty"`
	PublicURL          *string   `json:"publicUrl,omitempty"`
}

func LocalAppURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	host := strings.ToLower(u.Hostname())
	return host == "localhost" || (net.ParseIP(host) != nil && net.ParseIP(host).IsLoopback())
}

func normalizeApp(app AppShortcut) (AppShortcut, error) {
	app.Name, app.URL = strings.TrimSpace(app.Name), strings.TrimSpace(app.URL)
	app.StartupCommand = strings.TrimSpace(app.StartupCommand)
	app.StaticDirectory = strings.TrimSpace(app.StaticDirectory)
	app.PublicURL = strings.TrimSpace(app.PublicURL)
	if len(app.StaticDirectory) > 4096 || strings.ContainsRune(app.StaticDirectory, 0) {
		return app, invalid("invalid static build directory")
	}
	if app.PublicURL != "" {
		public, err := url.Parse(app.PublicURL)
		if err != nil || public.Scheme != "https" || public.Hostname() == "" || public.User != nil || LocalAppURL(app.PublicURL) || len(app.PublicURL) > 4096 {
			return app, invalid("publicUrl must be an HTTPS link without credentials")
		}
	}
	u, err := url.Parse(app.URL)
	validURL := err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Hostname() != "" && u.User == nil
	if app.Automation && app.URL == "" && app.StartupCommand == "" {
		validURL = true
	}
	if !validURL ||
		len(app.URL) > 4096 || !validID(app.ID) || !validID(app.ProjectID) || app.Name == "" || len(app.Name) > 120 ||
		!validAppIcon(app.Icon) || len(app.StartupCommand) > 8192 || strings.ContainsRune(app.StartupCommand, 0) {
		return app, invalid("an app needs a name, a valid HTTP(S) link and a supported icon")
	}
	if app.Automation && (app.URL != "" || app.StartupCommand != "" || app.HealthPath != "" || app.StaticDirectory != "" || app.PublicURL != "") {
		return app, invalid("automation shortcuts have schedules instead of a link or startup command")
	}
	if LocalAppURL(app.URL) && u.Hostname() != "localhost" && u.Hostname() != "127.0.0.1" && u.Hostname() != "::1" {
		return app, invalid("use 127.0.0.1, localhost or ::1 for local app links")
	}
	if validURL && app.URL != "" && u.Port() != "" {
		port, err := strconv.Atoi(u.Port())
		if err != nil || port < 1 || port > 65535 {
			return app, invalid("app link has an invalid port")
		}
	}
	app.ChannelIDs = slices.Compact(slices.Sorted(slices.Values(app.ChannelIDs)))
	if len(app.ChannelIDs) > 16 {
		return app, invalid("choose at most 16 notification channels")
	}
	for _, id := range app.ChannelIDs {
		if !validID(id) {
			return app, invalid("invalid notification channel")
		}
	}
	if app.HealthPath != "" {
		p, err := url.Parse(app.HealthPath)
		if err != nil || p.IsAbs() || p.Host != "" || !strings.HasPrefix(app.HealthPath, "/") || len(app.HealthPath) > 2048 || p.Fragment != "" {
			return app, invalid("healthPath must be a path on the app's own server")
		}
	}
	return app, nil
}

func validAppIcon(icon string) bool {
	if validBotIcon(icon) {
		return true
	}
	if len(icon) > 80 {
		return false
	}
	for _, c := range icon {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '-') {
			return false
		}
	}
	return icon != ""
}

func readApp(q queryer, id string) (AppShortcut, error) {
	var data []byte
	err := q.QueryRow("SELECT data FROM apps WHERE id=?", id).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return AppShortcut{}, ErrNotFound
	}
	if err != nil {
		return AppShortcut{}, err
	}
	var app AppShortcut
	err = json.Unmarshal(data, &app)
	return app, err
}

func readApps(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, minimum int64) ([]AppShortcut, error) {
	rows, err := q.Query("SELECT a.data FROM apps a JOIN projects p ON p.id=json_extract(a.data,'$.projectId') WHERE a.revision>? ORDER BY a.id", minimum)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	apps := []AppShortcut{}
	for rows.Next() {
		var data []byte
		var app AppShortcut
		if err = rows.Scan(&data); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(data, &app); err != nil {
			return nil, err
		}
		apps = append(apps, app)
	}
	return apps, rows.Err()
}

func (st *Store) App(id string) (AppShortcut, error) { return readApp(st.db, id) }
func (st *Store) Apps() ([]AppShortcut, error)       { return readApps(st.db, -1) }

func saveApp(tx *sql.Tx, app AppShortcut, revision int64) error {
	app.Revision = revision
	data, err := json.Marshal(app)
	if err != nil {
		return err
	}
	_, err = tx.Exec("INSERT INTO apps VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data,revision=excluded.revision", app.ID, data, revision)
	return err
}

func (st *Store) RegisterApp(app AppShortcut) (AppShortcut, error) {
	if app.ID == "" {
		key := strings.TrimSpace(app.URL)
		if app.Automation {
			key = "automation:" + strings.TrimSpace(app.Name)
		}
		sum := sha256.Sum256([]byte(st.identity + "\x00" + app.ProjectID + "\x00" + key))
		app.ID = "app-" + hex.EncodeToString(sum[:16])
	}
	var err error
	app, err = normalizeApp(app)
	if err != nil {
		return app, err
	}
	err = st.write(func(tx *sql.Tx, revision int64) (bool, error) {
		data, _, err := record(tx, "projects", app.ProjectID)
		if err != nil {
			return false, err
		}
		if data == nil {
			return false, ErrNotFound
		}
		if err = checkChatProject(tx, data); err != nil {
			return false, err
		}
		if app.BotID != "" {
			bot, err := readBot(tx, app.BotID)
			if err != nil {
				return false, err
			}
			var project Project
			if err := json.Unmarshal(data, &project); err != nil {
				return false, err
			}
			if bot.WorkspaceID != project.WorkspaceID {
				return false, invalid("app and bot must belong to the same workspace")
			}
		}
		old, err := readApp(tx, app.ID)
		if err == nil {
			candidate := app
			candidate.Record = old.Record
			if reflect.DeepEqual(candidate, old) {
				app = old
				return false, nil
			}
			return false, ErrConflict
		}
		if !errors.Is(err, ErrNotFound) {
			return false, err
		}
		var count int
		if err = tx.QueryRow("SELECT count(*) FROM apps").Scan(&count); err != nil {
			return false, err
		}
		if count >= 1024 {
			return false, invalid("this computer has reached its app limit")
		}
		app.Record = Record{ID: app.ID, WorkspaceID: st.identity, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano), Revision: revision}
		return true, saveApp(tx, app, revision)
	})
	return app, err
}

func (st *Store) UpdateApp(id string, patch AppShortcutPatch) (AppShortcut, error) {
	var app AppShortcut
	err := st.write(func(tx *sql.Tx, revision int64) (bool, error) {
		var err error
		app, err = readApp(tx, id)
		if err != nil {
			return false, err
		}
		if app.Revision != patch.ExpectedRevision {
			return false, ErrConflict
		}
		old := app
		if patch.Name != nil {
			app.Name = *patch.Name
		}
		if patch.Icon != nil {
			app.Icon = *patch.Icon
		}
		if patch.URL != nil {
			app.URL = *patch.URL
		}
		if patch.StartupCommand != nil {
			app.StartupCommand = *patch.StartupCommand
		}
		if patch.HealthPath != nil {
			app.HealthPath = *patch.HealthPath
		}
		if patch.Archived != nil {
			app.Archived = *patch.Archived
		}
		if patch.ChannelIDs != nil {
			app.ChannelIDs = *patch.ChannelIDs
		}
		if patch.NotificationsMuted != nil {
			app.NotificationsMuted = *patch.NotificationsMuted
		}
		if patch.StaticDirectory != nil {
			app.StaticDirectory = *patch.StaticDirectory
		}
		if app.URL != old.URL || app.StaticDirectory != old.StaticDirectory {
			app.PublicURL = ""
		}
		if patch.PublicURL != nil {
			app.PublicURL = *patch.PublicURL
		}
		app, err = normalizeApp(app)
		if err != nil {
			return false, err
		}
		if reflect.DeepEqual(app, old) {
			return false, nil
		}
		app.Revision = revision
		if app.Archived && !old.Archived {
			if _, err = tx.Exec("DELETE FROM app_token_grants WHERE app_id=?", id); err != nil {
				return false, err
			}
			if err = pauseAppSchedules(tx, id); err != nil {
				return false, err
			}
		}
		return true, saveApp(tx, app, revision)
	})
	return app, err
}

func (st *Store) AppDirectory(app AppShortcut) (string, error) {
	var raw []byte
	err := st.db.QueryRow("SELECT data FROM projects WHERE id=?", app.ProjectID).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if err = checkChatProject(st.db, raw); err != nil {
		return "", err
	}
	var project Project
	if err = json.Unmarshal(raw, &project); err != nil {
		return "", err
	}
	return project.Path, nil
}

func archiveProjectApps(tx *sql.Tx, projectID string, revision int64) error {
	rows, err := tx.Query("SELECT data FROM apps WHERE json_extract(data,'$.projectId')=?", projectID)
	if err != nil {
		return err
	}
	var apps []AppShortcut
	for rows.Next() {
		var raw []byte
		var app AppShortcut
		if err = rows.Scan(&raw); err != nil {
			rows.Close()
			return err
		}
		if err = json.Unmarshal(raw, &app); err != nil {
			rows.Close()
			return err
		}
		apps = append(apps, app)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, app := range apps {
		app.Archived = true
		if err = saveApp(tx, app, revision); err != nil {
			return err
		}
		if _, err = tx.Exec("DELETE FROM app_token_grants WHERE app_id=?", app.ID); err != nil {
			return err
		}
		if err = pauseAppSchedules(tx, app.ID); err != nil {
			return err
		}
	}
	return nil
}
