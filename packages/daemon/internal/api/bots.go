package api

import (
	"errors"
	"github.com/oblien/mindwire/packages/daemon/internal/bots"
	"github.com/oblien/mindwire/packages/daemon/internal/orchestrator"
	"net/http"

	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

func (a *API) botsList(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	bots, err := a.registry.Bots(r.URL.Query().Get("projectId"), r.URL.Query().Get("archived") == "true")
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, bots)
}

func (a *API) botsEnsure(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	var input struct {
		AgentID   string `json:"agentId"`
		ProjectID string `json:"projectId"`
	}
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "agentId and projectId are required")
		return
	}
	a.registryMu.Lock()
	defer a.registryMu.Unlock()
	bot, err := a.registry.EnsureMaster(input.AgentID, input.ProjectID)
	if err != nil {
		workspaceError(w, err)
		return
	}
	a.writeBotResult(w, bot)
}

func (a *API) botGet(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	bot, err := a.registry.Bot(r.PathValue("id"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, bot)
}

func (a *API) botCreate(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	var input registry.Bot
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid bot")
		return
	}
	a.registryMu.Lock()
	defer a.registryMu.Unlock()
	bot, err := a.registry.CreateBot(input)
	if err != nil {
		workspaceError(w, err)
		return
	}
	a.writeBotResult(w, bot)
}

func (a *API) botUpdate(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	var input registry.BotPatch
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid bot update")
		return
	}
	a.registryMu.Lock()
	defer a.registryMu.Unlock()
	bot, err := a.registry.UpdateBot(r.PathValue("id"), input)
	if err != nil {
		workspaceError(w, err)
		return
	}
	a.writeBotResult(w, bot)
}

func (a *API) writeBotResult(w http.ResponseWriter, bot registry.Bot) {
	snapshot, err := a.registry.Snapshot(nil)
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Bot      registry.Bot      `json:"bot"`
		Snapshot registry.Snapshot `json:"snapshot"`
	}{bot, snapshot})
}

func (a *API) botChats(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	chats, err := a.registry.BotChats(r.PathValue("id"))
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, chats)
}

func (a *API) botChatCreate(w http.ResponseWriter, r *http.Request) {
	if !a.requireRegistry(w) {
		return
	}
	var input struct {
		ChatID    string `json:"chatId"`
		Title     string `json:"title"`
		ProjectID string `json:"projectId,omitempty"`
	}
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid chat")
		return
	}
	a.registryMu.Lock()
	defer a.registryMu.Unlock()
	chat, err := a.registry.CreateBotChat(r.PathValue("id"), input.ChatID, input.Title, input.ProjectID)
	if err != nil {
		workspaceError(w, err)
		return
	}
	snapshot, err := a.registry.Snapshot(nil)
	if err != nil {
		workspaceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		ChatID   string            `json:"chatId"`
		Snapshot registry.Snapshot `json:"snapshot"`
	}{chat.ID, snapshot})
}

func (a *API) botService(w http.ResponseWriter) *bots.Service {
	if !a.requireRegistry(w) {
		return nil
	}
	service := a.sup.BotService()
	if service == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "bot execution is unavailable; update the daemon"})
	}
	return service
}

func botTaskError(w http.ResponseWriter, err error) {
	if turnRequestError(w, err) {
		return
	}
	if errors.Is(err, orchestrator.ErrChatBusy) || errors.Is(err, orchestrator.ErrServiceUpdating) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	if errors.Is(err, registry.ErrInvalid) || errors.Is(err, registry.ErrConflict) || errors.Is(err, registry.ErrDeleted) || errors.Is(err, registry.ErrNotFound) {
		workspaceError(w, err)
		return
	}
	// Runtime/auth/software failures are actionable bot errors, not a claim
	// that saving registry metadata failed.
	writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
}

func (a *API) botAgents(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	agents, projects, err := service.Agents(registry.Bot{})
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"agents": agents, "projects": projects})
}

func (a *API) botTasks(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	tasks, err := service.Tasks(registry.Bot{}, r.PathValue("id"))
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, tasks)
}

func (a *API) botTaskCreate(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	var input bots.TaskRequest
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid task")
		return
	}
	task, err := service.Delegate(registry.Bot{}, r.PathValue("id"), input)
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, task)
}

func (a *API) botTaskGet(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	task, err := service.Task(registry.Bot{}, r.PathValue("id"), r.PathValue("runId"))
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, task)
}

func (a *API) botTaskInput(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	var input bots.TaskInput
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid follow-up")
		return
	}
	task, err := service.Input(registry.Bot{}, r.PathValue("id"), r.PathValue("runId"), input)
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, task)
}

func (a *API) botTaskCancel(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	task, err := service.CancelTask(registry.Bot{}, r.PathValue("id"), r.PathValue("runId"))
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, task)
}

func (a *API) botPeerIdentity(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	identity, err := service.PeerIdentity()
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, identity)
}
func (a *API) botPeerListener(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	var input struct {
		Port int `json:"port,omitempty"`
	}
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid peer listener request")
		return
	}
	identity, err := service.StartPeerListener(input.Port)
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, identity)
}
func (a *API) botPeers(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	peers, err := service.Peers()
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, peers)
}
func (a *API) botPeerPut(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	var input bots.Peer
	input.Enabled = true
	if err := decode(w, r, &input); err != nil {
		badRequest(w, "invalid computer link")
		return
	}
	peer, err := service.SavePeer(r.PathValue("workspaceId"), input)
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, peer)
}
func (a *API) botPeerDelete(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	if err := service.RemovePeer(r.PathValue("workspaceId")); err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *API) botPeerCheck(w http.ResponseWriter, r *http.Request) {
	service := a.botService(w)
	if service == nil {
		return
	}
	result, err := service.CheckPeer(r.Context(), r.PathValue("workspaceId"))
	if err != nil {
		botTaskError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}
