package api

import (
	"encoding/json"
	"net/http"

	"github.com/oblien/mindwire/packages/daemon/internal/projecticon"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

// A path previews an in-project candidate; omitting it reads the saved icon.
// The same authenticated endpoint is used through cloud proxies and paired SSH.
func (a *API) projectIcon(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	p, err := a.registry.Project(r.PathValue("id"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	name := r.URL.Query().Get("path")
	if name == "" && p.IconPath != nil {
		name = *p.IconPath
	}
	if name == "" {
		workspaceError(w, registry.ErrNotFound)
		return
	}
	icon, err := projecticon.Read(p.Path, name)
	if err != nil {
		badRequest(w, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "private, no-store")
	writeJSON(w, http.StatusOK, icon)
}

func (a *API) projectIconUpload(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	p, err := a.registry.Project(r.PathValue("id"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	var input struct {
		Name    string `json:"name"`
		Content []byte `json:"content"`
	}
	// JSON base64 expands the bounded image by 4/3. Cap before decoding.
	r.Body = http.MaxBytesReader(w, r.Body, (projecticon.MaxBytes+2)/3*4+4096)
	if err = json.NewDecoder(r.Body).Decode(&input); err != nil {
		badRequest(w, "choose an image smaller than 1 MB")
		return
	}
	icon, err := projecticon.Upload(p.Path, input.Name, input.Content)
	if err != nil {
		badRequest(w, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "private, no-store")
	writeJSON(w, http.StatusOK, icon)
}
