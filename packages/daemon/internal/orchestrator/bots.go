package orchestrator

import (
	"fmt"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/bots"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"github.com/oblien/mindwire/packages/daemon/internal/session"
)

func (s *Supervisor) SetBots(service *bots.Service) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if service != nil {
		service.SetRuntime(s)
	}
	s.bots = service
	if s.botTasks == nil {
		s.botTasks = map[string]string{}
	}
}

func (s *Supervisor) BotService() *bots.Service {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.bots
}

// Admission runs under the same lock as ordinary turns. Native idempotency is
// checked first, so retries remain valid even while every task slot is occupied.
func (s *Supervisor) botTaskAdmissionLocked(botID string) error {
	if botID == "" {
		return nil
	}
	for _, id := range s.botTasks {
		if id == botID {
			return fmt.Errorf("%w: this bot already has a delegated task; inspect or steer it before starting another", ErrChatBusy)
		}
	}
	if len(s.botTasks) >= 4 {
		return fmt.Errorf("%w: four delegated tasks are already running on this computer", ErrChatBusy)
	}
	return nil
}

func (s *Supervisor) StartBotTurn(botID string, chat registry.Chat, profile registry.Agent, project registry.Project, message, requestID string) (session.Run, error) {
	a, ok := s.Resolve(profile.AgentType)
	if !ok {
		return session.Run{}, fmt.Errorf("%w: this bot's base AI connection is unavailable", registry.ErrInvalid)
	}
	if err := s.checkBotEngine(a, chat.ID); err != nil {
		return session.Run{}, err
	}
	return s.StartTurnChecked(a, StartTurnInput{ChatID: chat.ID, CWD: project.Path, Message: message, RequestID: requestID, botID: botID})
}

func (s *Supervisor) checkBotEngine(a *Agent, chatID string) error {
	if !a.Capabilities().BotProfiles {
		if service := s.BotService(); service != nil && service.IsBotChat(chatID) {
			return fmt.Errorf("%w: this AI connection cannot refresh bot instructions in resumed chats; choose a supported connection", registry.ErrInvalid)
		}
	}
	return nil
}

func (s *Supervisor) BotRunSnapshot(runID string) (session.Run, []agent.Part, bool) {
	snapshot, ok := s.Snapshot(runID)
	return snapshot.Run, snapshot.Parts, ok
}
