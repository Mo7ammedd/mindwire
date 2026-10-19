package mindwire

import (
	"context"
	"errors"
	"net/http"

	botservice "github.com/oblien/mindwire/packages/daemon/internal/bots"
	"github.com/oblien/mindwire/packages/daemon/internal/orchestrator"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"github.com/oblien/mindwire/packages/daemon/internal/session"
)

type Bot = registry.Bot
type BotKnowledge = registry.BotKnowledge
type BotEdit = registry.BotPatch
type BotTask = botservice.Task
type BotTaskRequest = botservice.TaskRequest
type BotTaskInput = botservice.TaskInput
type BotTaskMessage = botservice.ChatExcerpt
type BotTaskInteraction = botservice.TaskInteraction
type BotTaskTool = botservice.TaskTool
type BotPeer = botservice.Peer
type BotPeerRoute = botservice.PeerRoute
type BotPeerIdentity = botservice.PeerIdentity
type BotPeerCheck = botservice.PeerCheck
type BotMutation struct {
	Bot      Bot               `json:"bot"`
	Snapshot WorkspaceSnapshot `json:"snapshot"`
}

// Bots is the persisted identity and native task layer shared by all harnesses.
type Bots struct{ c *Client }

func (b *Bots) List(projectID string, includeArchived bool) ([]Bot, error) {
	value, err := b.c.core.registry.Bots(projectID, includeArchived)
	return value, workspaceError("Bots.List", err)
}
func (b *Bots) Get(id string) (Bot, error) {
	value, err := b.c.core.registry.Bot(id)
	return value, workspaceError("Bots.Get", err)
}
func (b *Bots) Ensure(agentID, projectID string) (BotMutation, error) {
	b.c.core.registryMu.Lock()
	defer b.c.core.registryMu.Unlock()
	bot, err := b.c.core.registry.EnsureMaster(agentID, projectID)
	return b.result(bot, err)
}
func (b *Bots) Create(bot Bot) (BotMutation, error) {
	b.c.core.registryMu.Lock()
	defer b.c.core.registryMu.Unlock()
	value, err := b.c.core.registry.CreateBot(bot)
	return b.result(value, err)
}
func (b *Bots) Update(id string, edit BotEdit) (BotMutation, error) {
	b.c.core.registryMu.Lock()
	defer b.c.core.registryMu.Unlock()
	value, err := b.c.core.registry.UpdateBot(id, edit)
	return b.result(value, err)
}
func (b *Bots) Chats(id string) ([]WorkspaceChat, error) {
	value, err := b.c.core.registry.BotChats(id)
	return value, workspaceError("Bots.Chats", err)
}
func (b *Bots) CreateChat(id, chatID, title string, projectIDs ...string) (WorkspaceChat, error) {
	b.c.core.registryMu.Lock()
	defer b.c.core.registryMu.Unlock()
	value, err := b.c.core.registry.CreateBotChat(id, chatID, title, projectIDs...)
	return value, workspaceError("Bots.CreateChat", err)
}
func (b *Bots) result(bot Bot, err error) (BotMutation, error) {
	if err != nil {
		return BotMutation{}, workspaceError("Bots.Edit", err)
	}
	snapshot, err := b.c.core.registry.Snapshot(nil)
	return BotMutation{Bot: bot, Snapshot: snapshot}, workspaceError("Bots.Edit", err)
}

func (b *Bots) Agents() ([]WorkspaceAgent, []WorkspaceProject, error) {
	agents, projects, err := b.c.core.sup.BotService().Agents(registry.Bot{})
	return agents, projects, workspaceError("Bots.Agents", err)
}

func (b *Bots) PeerIdentity() (BotPeerIdentity, error) {
	identity, err := b.c.core.sup.BotService().PeerIdentity()
	return identity, workspaceError("Bots.PeerIdentity", err)
}

// StartPeerListener persists a dedicated bot-only SSH/WebSocket listener.
// Port zero selects an available port. Cloud routing is provisioned separately.
func (b *Bots) StartPeerListener(port int) (BotPeerIdentity, error) {
	identity, err := b.c.core.sup.BotService().StartPeerListener(port)
	return identity, workspaceError("Bots.StartPeerListener", err)
}

func (b *Bots) Peers() ([]BotPeer, error) {
	peers, err := b.c.core.sup.BotService().Peers()
	return peers, workspaceError("Bots.Peers", err)
}

// Pair stores an explicitly authorized public identity. Set Enabled to grant access.
func (b *Bots) Pair(workspaceID string, peer BotPeer) (BotPeer, error) {
	value, err := b.c.core.sup.BotService().SavePeer(workspaceID, peer)
	return value, workspaceError("Bots.Pair", err)
}

func (b *Bots) RevokePeer(workspaceID string) error {
	return workspaceError("Bots.RevokePeer", b.c.core.sup.BotService().RemovePeer(workspaceID))
}

// CheckPeer confirms a pinned bot-only connection without starting a native task.
func (b *Bots) CheckPeer(ctx context.Context, workspaceID string) (BotPeerCheck, error) {
	check, err := b.c.core.sup.BotService().CheckPeer(ctx, workspaceID)
	return check, workspaceError("Bots.CheckPeer", err)
}

func (b *Bots) Tasks(id string) ([]BotTask, error) {
	tasks, err := b.c.core.sup.BotService().Tasks(registry.Bot{}, id)
	return tasks, botTaskError("Bots.Tasks", err)
}

// Delegate starts a native turn. Reuse RequestID when retrying the same intent.
func (b *Bots) Delegate(id string, input BotTaskRequest) (BotTask, error) {
	task, err := b.c.core.sup.BotService().Delegate(registry.Bot{}, id, input)
	if err == nil {
		b.c.core.track(task.Run.ID)
	}
	return task, botTaskError("Bots.Delegate", err)
}

func (b *Bots) Task(id, runID string) (BotTask, error) {
	task, err := b.c.core.sup.BotService().Task(registry.Bot{}, id, runID)
	return task, botTaskError("Bots.Task", err)
}

func (b *Bots) Input(id, runID string, input BotTaskInput) (BotTask, error) {
	task, err := b.c.core.sup.BotService().Input(registry.Bot{}, id, runID, input)
	if err == nil {
		b.c.core.track(task.Run.ID)
	}
	return task, botTaskError("Bots.Input", err)
}

func (b *Bots) Cancel(id, runID string) (BotTask, error) {
	task, err := b.c.core.sup.BotService().CancelTask(registry.Bot{}, id, runID)
	return task, botTaskError("Bots.Cancel", err)
}

func botTaskError(op string, err error) error {
	if err == nil {
		return nil
	}
	status := 0
	switch {
	case errors.Is(err, orchestrator.ErrChatBusy), errors.Is(err, orchestrator.ErrServiceUpdating),
		errors.Is(err, orchestrator.ErrInputQueueFull), errors.Is(err, session.ErrTurnRequestConflict):
		status = http.StatusConflict
	case errors.Is(err, orchestrator.ErrInvalidTurnRequest), errors.Is(err, orchestrator.ErrInputUnsupported),
		errors.Is(err, orchestrator.ErrInputOptions):
		status = http.StatusBadRequest
	}
	if status == 0 {
		return workspaceError(op, err)
	}
	return &APIError{Message: err.Error(), Status: status, Op: op, Cause: err}
}
