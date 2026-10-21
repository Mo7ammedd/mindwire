package api

import (
	"errors"
	"net/http"

	"github.com/oblien/mindwire/packages/daemon/internal/handoffs"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

func (a *API) handoffService() *handoffs.Service {
	return &handoffs.Service{Registry: a.registry, Store: a.store, Supervisor: a.sup, Mutation: &a.registryMu}
}

func handoffError(w http.ResponseWriter, err error) {
	if errors.Is(err, handoffs.ErrPreviewChanged) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error(), "code": "handoff_context_changed"})
		return
	}
	if errors.Is(err, registry.ErrInvalid) || errors.Is(err, registry.ErrNotFound) || errors.Is(err, registry.ErrDeleted) || errors.Is(err, registry.ErrConflict) {
		workspaceError(w, err)
		return
	}
	if turnRequestError(w, err) {
		return
	}
	if isGitError(err) {
		gitError(w, err)
		return
	}
	writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
}

func (a *API) handoffPreview(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	preview, err := a.handoffService().Preview(r.Context(), r.PathValue("id"))
	if err != nil {
		handoffError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, preview)
}

func (a *API) handoffStart(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	var input handoffs.Request
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid handoff request")
		return
	}
	result, err := a.handoffService().Start(r.Context(), r.PathValue("id"), input)
	if err != nil {
		handoffError(w, err)
		return
	}
	snapshot, err := a.registry.Snapshot(nil)
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, struct {
		handoffs.Result
		Snapshot registry.Snapshot `json:"snapshot"`
	}{result, snapshot})
}
