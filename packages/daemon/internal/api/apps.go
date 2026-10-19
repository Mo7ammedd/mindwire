package api

import (
	"net/http"

	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

func (a *API) appsList(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	apps, err := a.registry.Apps()
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, apps)
}

func (a *API) appGet(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	app, err := a.registry.App(r.PathValue("id"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, app)
}

func (a *API) appRegister(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	var input registry.AppShortcut
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid app shortcut")
		return
	}
	a.registryMu.Lock()
	defer a.registryMu.Unlock()
	app, err := a.registry.RegisterApp(input)
	if err != nil {
		workspaceError(w, err)
		return
	}
	a.writeAppResult(w, app)
}

func (a *API) appUpdate(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	var input registry.AppShortcutPatch
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid app update")
		return
	}
	a.registryMu.Lock()
	defer a.registryMu.Unlock()
	app, err := a.registry.UpdateApp(r.PathValue("id"), input)
	if err != nil {
		workspaceError(w, err)
		return
	}
	a.writeAppResult(w, app)
}

func (a *API) writeAppResult(w http.ResponseWriter, app registry.AppShortcut) {
	snapshot, err := a.registry.Snapshot(nil)
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"app": app, "snapshot": snapshot})
}

func (a *API) appOpen(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	if a.apps == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "app shortcuts are unavailable"})
		return
	}
	app, err := a.apps.Open(r.Context(), r.PathValue("id"))
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, app)
}

func (a *API) appPublication(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	if a.apps == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "app shortcuts are unavailable"})
		return
	}
	plan, err := a.apps.PreparePublication(r.Context(), r.PathValue("id"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, plan)
}
