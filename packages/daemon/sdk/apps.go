package mindwire

import (
	"context"

	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"github.com/oblien/mindwire/packages/daemon/internal/shortcuts"
)

type AppShortcut = registry.AppShortcut
type AppShortcutEdit = registry.AppShortcutPatch
type AppPublication = shortcuts.Publication
type AppSchedule = registry.AppSchedule
type AppScheduleSpec = registry.AppScheduleSpec
type AppNotificationChannel = shortcuts.Channel
type AppNotificationMessage = shortcuts.NotificationMessage
type AppShortcutMutation struct {
	App      AppShortcut       `json:"app"`
	Snapshot WorkspaceSnapshot `json:"snapshot"`
}

// Apps exposes application resources, readiness, scoped notifications and persisted
// schedules. Background execution is opt-in via Options.RunScheduledJobs.
type Apps struct{ c *Client }

func (a *Apps) List() ([]AppShortcut, error) {
	value, err := a.c.core.registry.Apps()
	return value, workspaceError("Apps.List", err)
}
func (a *Apps) Get(id string) (AppShortcut, error) {
	value, err := a.c.core.registry.App(id)
	return value, workspaceError("Apps.Get", err)
}
func (a *Apps) Register(input AppShortcut) (AppShortcutMutation, error) {
	a.c.core.registryMu.Lock()
	defer a.c.core.registryMu.Unlock()
	value, err := a.c.core.registry.RegisterApp(input)
	return a.result(value, err)
}
func (a *Apps) Update(id string, input AppShortcutEdit) (AppShortcutMutation, error) {
	a.c.core.registryMu.Lock()
	defer a.c.core.registryMu.Unlock()
	value, err := a.c.core.registry.UpdateApp(id, input)
	return a.result(value, err)
}
func (a *Apps) Open(ctx context.Context, id string) (AppShortcut, error) {
	value, err := a.c.core.apps.Open(ctx, id)
	return value, workspaceError("Apps.Open", err)
}

func (a *Apps) PreparePublication(ctx context.Context, id string) (AppPublication, error) {
	value, err := a.c.core.apps.PreparePublication(ctx, id)
	return value, workspaceError("Apps.PreparePublication", err)
}

func (a *Apps) Channels() []AppNotificationChannel { return a.c.core.apps.Channels() }
func (a *Apps) Notify(ctx context.Context, id string, message AppNotificationMessage) error {
	return a.c.core.apps.Notify(ctx, id, message)
}
func (a *Apps) RevokeNotificationAccess(id string) error {
	return a.c.core.apps.RevokeNotifications(id)
}
func (a *Apps) Schedules(id string) ([]AppSchedule, error) { return a.c.core.registry.AppSchedules(id) }
func (a *Apps) SaveSchedule(id string, spec AppScheduleSpec) (AppSchedule, error) {
	job, err := a.c.core.apps.SaveSchedule(id, spec)
	return job, workspaceError("Apps.SaveSchedule", err)
}
func (a *Apps) DeleteSchedule(id, jobID string) error {
	err := a.c.core.apps.DeleteSchedule(id, jobID)
	return workspaceError("Apps.DeleteSchedule", err)
}
func (a *Apps) result(app AppShortcut, err error) (AppShortcutMutation, error) {
	if err != nil {
		return AppShortcutMutation{}, workspaceError("Apps.Edit", err)
	}
	snapshot, err := a.c.core.registry.Snapshot(nil)
	return AppShortcutMutation{App: app, Snapshot: snapshot}, workspaceError("Apps.Edit", err)
}
