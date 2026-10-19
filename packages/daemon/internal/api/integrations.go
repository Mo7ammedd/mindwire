package api

import (
	"net/http"

	"github.com/oblien/mindwire/packages/daemon/internal/integrations"
)

func (a *API) integrationService(w http.ResponseWriter) *integrations.Service {
	if a.integrations == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "integrations require a workspace registry"})
	}
	return a.integrations
}
func (a *API) integrationsList(w http.ResponseWriter, r *http.Request) {
	s := a.integrationService(w)
	if s == nil {
		return
	}
	value, err := s.List()
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, 200, value)
}
func (a *API) integrationGet(w http.ResponseWriter, r *http.Request) {
	s := a.integrationService(w)
	if s == nil {
		return
	}
	value, err := s.Get(r.PathValue("id"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, 200, value)
}
func (a *API) integrationSave(w http.ResponseWriter, r *http.Request) {
	s := a.integrationService(w)
	if s == nil {
		return
	}
	var spec integrations.Spec
	if err := decode(w, r, &spec); err != nil {
		badRequest(w, "invalid integration configuration")
		return
	}
	value, err := s.Save(r.PathValue("id"), spec)
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, 200, value)
}
func (a *API) integrationDelete(w http.ResponseWriter, r *http.Request) {
	s := a.integrationService(w)
	if s == nil {
		return
	}
	if err := s.Delete(r.PathValue("id")); err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"deleted": true})
}
func (a *API) integrationSend(w http.ResponseWriter, r *http.Request) {
	s := a.integrationService(w)
	if s == nil {
		return
	}
	var input struct {
		Text string `json:"text"`
	}
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid message")
		return
	}
	if err := s.Send(r.Context(), r.PathValue("id"), input.Text); err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"sent": true})
}
func (a *API) integrationEvents(w http.ResponseWriter, r *http.Request) {
	s := a.integrationService(w)
	if s == nil {
		return
	}
	events, err := s.Events(r.PathValue("id"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, 200, events)
}
func (a *API) integrationRetry(w http.ResponseWriter, r *http.Request) {
	s := a.integrationService(w)
	if s == nil {
		return
	}
	event, err := s.Retry(r.PathValue("id"), r.PathValue("eventId"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, event)
}
func (a *API) IntegrationWebhook(w http.ResponseWriter, r *http.Request) {
	if s := a.integrationService(w); s != nil {
		a.serviceOperation(s.Webhook)(w, r)
	}
}
