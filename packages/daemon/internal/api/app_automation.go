package api

import (
	"net"
	"net/http"
	"strings"

	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"github.com/oblien/mindwire/packages/daemon/internal/shortcuts"
)

func (a *API) SetAppsAddress(address string) error {
	if a.apps == nil {
		return nil
	}
	return a.apps.SetAddress(address)
}

// StartScheduledJobs is called explicitly by the long-lived daemon host.
func (a *API) StartScheduledJobs() error {
	if a.initError != nil {
		return a.initError
	}
	if a.apps == nil {
		return nil
	}
	return a.apps.StartScheduler()
}
func (a *API) appChannels(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	writeJSON(w, http.StatusOK, a.apps.Channels())
}
func (a *API) appNotificationSetup(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	var input struct {
		ChannelIDs []string `json:"channelIds"`
		Rotate     bool     `json:"rotate"`
	}
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid notification setup")
		return
	}
	app, path, err := a.apps.NotificationSetup(r.PathValue("id"), input.ChannelIDs, input.Rotate)
	if err != nil {
		botTaskError(w, err)
		return
	}
	snapshot, err := a.registry.Snapshot(nil)
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"app": app, "credentialFile": path, "snapshot": snapshot})
}
func (a *API) appNotificationRevoke(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	if err := a.apps.RevokeNotifications(r.PathValue("id")); err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}

// AppNotify authenticates ONLY the app-scoped credential. It is loopback-only,
// cannot choose a recipient or another app, and never accepts the owner token.
func (a *API) AppNotify(w http.ResponseWriter, r *http.Request) {
	a.serviceOperation(a.appNotify)(w, r)
}

func (a *API) appNotify(w http.ResponseWriter, r *http.Request) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || r.Header.Get("Origin") != "" || a.apps == nil || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") || !a.apps.AuthorizedNotification(r.PathValue("id"), strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid app notification credential"})
		return
	}
	var input shortcuts.NotificationMessage
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid app notification")
		return
	}
	if err = a.apps.Notify(r.Context(), r.PathValue("id"), input); err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"accepted": true})
}
func (a *API) appSchedules(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	jobs, err := a.registry.AppSchedules(r.PathValue("id"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, jobs)
}
func (a *API) appScheduleSave(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	var input registry.AppScheduleSpec
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid schedule")
		return
	}
	job, err := a.apps.SaveSchedule(r.PathValue("id"), input)
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, job)
}
func (a *API) appScheduleDelete(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	if err := a.apps.DeleteSchedule(r.PathValue("id"), r.PathValue("jobId")); err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"removed": true})
}
