package registry

import (
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/oblien/mindwire/packages/daemon/internal/notify"
)

func (st *Store) NotificationIdentity(chatID string) (notify.BotIdentity, error) {
	chat, _, _, err := st.ChatContext(chatID)
	if err != nil || chat == nil || chat.BotID == "" {
		return notify.BotIdentity{}, err
	}
	bot, err := st.Bot(chat.BotID)
	if err != nil {
		return notify.BotIdentity{}, err
	}
	return notify.BotIdentity{ID: bot.ID, Name: bot.Name, Icon: bot.Icon, WorkspaceID: bot.WorkspaceID}, nil
}

// NotificationsMuted follows the chat's identity: bot chats inherit only their bot's
// preference, while unassigned Developer chats retain their legacy engine preference.
// Unregistered native/legacy chats retain the default delivery behavior.
func (st *Store) NotificationsMuted(chatID string) (bool, error) {
	chat, profile, _, err := st.ChatContext(chatID)
	if errors.Is(err, ErrDeleted) {
		return true, nil
	}
	if err != nil || chat == nil {
		return false, err
	}
	if chat.NotificationsMuted != nil && *chat.NotificationsMuted {
		return true, nil
	}
	if chat.BotID != "" {
		bot, err := st.Bot(chat.BotID)
		return bot.NotificationsMuted != nil && *bot.NotificationsMuted, err
	}
	return profile.NotificationsMuted != nil && *profile.NotificationsMuted, nil
}

// Copy existing choices once when upgrading from engine-wide preferences. Subsequent
// engine changes never mute another bot. Publish a registry revision so connected
// clients receive the migrated preferences through their ordinary delta stream.
func migrateBotNotifications(tx *sql.Tx) error {
	bots, err := readBots(tx, -1)
	if err != nil {
		return err
	}
	var changed []Bot
	for _, bot := range bots {
		if bot.NotificationsMuted != nil {
			continue
		}
		data, _, err := record(tx, "agents", bot.AgentID)
		if err != nil {
			return err
		}
		var profile Agent
		if err = json.Unmarshal(data, &profile); err != nil {
			return err
		}
		muted := profile.NotificationsMuted != nil && *profile.NotificationsMuted
		bot.NotificationsMuted = &muted
		changed = append(changed, bot)
	}
	if len(changed) == 0 {
		return nil
	}
	var revision int64
	if err = tx.QueryRow("UPDATE meta SET revision=revision+1 WHERE id=1 RETURNING revision").Scan(&revision); err != nil {
		return err
	}
	for _, bot := range changed {
		if err = saveBot(tx, bot, revision); err != nil {
			return err
		}
	}
	return nil
}
