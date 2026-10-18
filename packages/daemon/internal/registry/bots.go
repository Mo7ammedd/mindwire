package registry

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"time"
)

const BotsVersion = 4

// SetBotEngines binds the hosting runtime's capability matrix once it attaches
// the bot service. Metadata-only registry users can still read/import records
// without registering executable adapters.
func (st *Store) SetBotEngines(ids []string) {
	engines := make(map[string]bool, len(ids))
	for _, id := range ids {
		engines[id] = true
	}
	st.botEngines.Store(&engines)
}

func (st *Store) checkBotEngine(profile Agent) error {
	if engines := st.botEngines.Load(); engines != nil && !(*engines)[profile.AgentType] {
		return invalid("this AI connection cannot update bot instructions in ongoing chats; choose a different connection")
	}
	return nil
}

// Bots are named assistants in General and Developer mode. They reuse a real agent/project, never another
// transcript or credential store. Knowledge and memory stay with this profile.
type Bot struct {
	Record
	AgentID            string         `json:"agentId"`
	ProjectID          string         `json:"projectId"`
	Name               string         `json:"name"`
	Icon               string         `json:"icon,omitempty"`
	Purpose            string         `json:"purpose"`
	Instructions       string         `json:"instructions"`
	Memory             string         `json:"memory"`
	Knowledge          []BotKnowledge `json:"knowledge"`
	IsMaster           bool           `json:"isMaster"`
	Archived           bool           `json:"archived"`
	NotificationsMuted *bool          `json:"notificationsMuted,omitempty"`
}

type BotKnowledge struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Content string `json:"content"`
}

type BotPatch struct {
	ExpectedRevision   int64           `json:"expectedRevision"`
	Name               *string         `json:"name,omitempty"`
	Icon               *string         `json:"icon,omitempty"`
	Purpose            *string         `json:"purpose,omitempty"`
	Instructions       *string         `json:"instructions,omitempty"`
	Memory             *string         `json:"memory,omitempty"`
	Knowledge          *[]BotKnowledge `json:"knowledge,omitempty"`
	Archived           *bool           `json:"archived,omitempty"`
	NotificationsMuted *bool           `json:"notificationsMuted,omitempty"`
}

func MasterBotID(projectID string) string {
	sum := sha256.Sum256([]byte(projectID))
	return "mindwire-" + hex.EncodeToString(sum[:12])
}

func readBot(q queryer, id string) (Bot, error) {
	var data []byte
	err := q.QueryRow("SELECT data FROM bots WHERE id=?", id).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return Bot{}, ErrNotFound
	}
	if err != nil {
		return Bot{}, err
	}
	var bot Bot
	err = json.Unmarshal(data, &bot)
	return bot, err
}

func (st *Store) Bot(id string) (Bot, error) { return readBot(st.db, id) }

func readBots(q interface {
	Query(string, ...any) (*sql.Rows, error)
}, minimum int64) ([]Bot, error) {
	rows, err := q.Query("SELECT b.data FROM bots b JOIN projects p ON p.id=json_extract(b.data,'$.projectId') JOIN agents a ON a.id=json_extract(b.data,'$.agentId') WHERE b.revision>? ORDER BY b.id", minimum)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	bots := []Bot{}
	for rows.Next() {
		var data []byte
		var bot Bot
		if err := rows.Scan(&data); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(data, &bot); err != nil {
			return nil, err
		}
		bots = append(bots, bot)
	}
	return bots, rows.Err()
}

func (st *Store) Bots(projectID string, includeArchived bool) ([]Bot, error) {
	all, err := readBots(st.db, -1)
	if err != nil {
		return nil, err
	}
	out := []Bot{}
	for _, bot := range all {
		if (projectID == "" || bot.ProjectID == projectID) && (includeArchived || !bot.Archived) {
			out = append(out, bot)
		}
	}
	return out, nil
}

func botParents(tx *sql.Tx, agentID, projectID string) (Agent, Project, error) {
	a, _, err := record(tx, "agents", agentID)
	if err != nil {
		return Agent{}, Project{}, err
	}
	p, _, err := record(tx, "projects", projectID)
	if err != nil {
		return Agent{}, Project{}, err
	}
	if a == nil || p == nil {
		return Agent{}, Project{}, ErrNotFound
	}
	var profile Agent
	var project Project
	if err = json.Unmarshal(a, &profile); err != nil {
		return profile, project, err
	}
	if err = json.Unmarshal(p, &project); err != nil {
		return profile, project, err
	}
	if err = checkChatProject(tx, p); err != nil {
		return profile, project, err
	}
	return profile, project, nil
}

func normalizeBot(bot Bot) (Bot, error) {
	bot.Name = strings.TrimSpace(bot.Name)
	bot.Purpose = strings.TrimSpace(bot.Purpose)
	bot.Instructions = strings.TrimSpace(bot.Instructions)
	bot.Memory = strings.TrimSpace(bot.Memory)
	if !validBotIcon(bot.Icon) {
		return Bot{}, invalid("invalid bot icon; choose a palette color and character")
	}
	bot.IsMaster = bot.ID == MasterBotID(bot.ProjectID)
	if !validID(bot.ID) || !validID(bot.AgentID) || !validID(bot.ProjectID) || bot.Name == "" || len(bot.Name) > 120 || len(bot.Purpose) > 2048 || len(bot.Instructions) > 32768 || len(bot.Memory) > 16384 {
		return Bot{}, invalid("bot name, context, instructions or memory exceed their limits")
	}
	if bot.IsMaster && (bot.Archived || bot.Name != "Mindwire") {
		return Bot{}, invalid("Mindwire cannot be archived or renamed")
	}
	if bot.Knowledge == nil {
		bot.Knowledge = []BotKnowledge{}
	}
	if len(bot.Knowledge) > 32 {
		return Bot{}, invalid("a bot supports up to 32 knowledge sources")
	}
	seen, size := map[string]bool{}, 0
	for i := range bot.Knowledge {
		source := &bot.Knowledge[i]
		source.Title = strings.TrimSpace(source.Title)
		if !validID(source.ID) || seen[source.ID] || source.Title == "" || len(source.Title) > 256 || len(source.Content) > 65536 {
			return Bot{}, invalid("invalid or duplicate knowledge source")
		}
		seen[source.ID] = true
		size += len(source.Content)
	}
	if size > 262144 {
		return Bot{}, invalid("bot knowledge exceeds 256 KiB; split or summarize the sources")
	}
	return bot, nil
}

func validBotIcon(icon string) bool {
	if icon == "" {
		return true // Automatic identity for existing profiles.
	}
	color, shape, ok := strings.Cut(icon, "-")
	return ok && slices.Contains([]string{"mint", "amber", "lilac", "blue", "peach", "rose", "olive", "cyan", "coral", "periwinkle"}, color) &&
		slices.Contains([]string{"pebble", "squircle", "sprout", "bean", "bloom", "spark", "drop", "arch", "orbit", "comet", "cloud", "clover", "flame", "moon", "fox", "cat", "ghost", "robot", "jelly", "leaf", "mushroom", "diamond", "crystal", "heart"}, shape)
}

func saveBot(tx *sql.Tx, bot Bot, revision int64) error {
	bot.Revision = revision
	data, err := json.Marshal(bot)
	if err != nil {
		return err
	}
	_, err = tx.Exec("INSERT INTO bots VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data,revision=excluded.revision", bot.ID, data, revision)
	return err
}

// EnsureMaster migrates only the General setup's project. It is atomic and
// repeatable; existing Developer projects and already assigned chats are untouched.
func (st *Store) EnsureMaster(agentID, projectID string) (Bot, error) {
	var result Bot
	err := st.write(func(tx *sql.Tx, revision int64) (bool, error) {
		profile, _, err := botParents(tx, agentID, projectID)
		if err != nil {
			return false, err
		}
		if err := st.checkBotEngine(profile); err != nil {
			return false, err
		}
		id := MasterBotID(projectID)
		bot, err := readBot(tx, id)
		changed := false
		if errors.Is(err, ErrNotFound) {
			bot = Bot{Record: Record{ID: id, WorkspaceID: st.identity, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano)},
				AgentID: agentID, ProjectID: projectID, Name: "Mindwire", Purpose: "Your main assistant. Create and improve bots, and get things done.", IsMaster: true, Knowledge: []BotKnowledge{}}
			changed = true
		} else if err != nil {
			return false, err
		}
		if bot.ProjectID != projectID || !bot.IsMaster {
			return false, ErrConflict
		}
		if bot.AgentID != agentID {
			bot.AgentID = agentID
			changed = true
		}
		if changed {
			if err := saveBot(tx, bot, revision); err != nil {
				return false, err
			}
			bot.Revision = revision
		}
		rows, err := tx.Query("SELECT data FROM chats WHERE project_id=? AND NOT EXISTS (SELECT 1 FROM deleted WHERE kind='chats' AND deleted.id=chats.id)", projectID)
		if err != nil {
			return false, err
		}
		var migrated []Chat
		for rows.Next() {
			var data []byte
			var chat Chat
			if err = rows.Scan(&data); err == nil {
				err = json.Unmarshal(data, &chat)
			}
			if err != nil {
				rows.Close()
				return false, err
			}
			if chat.BotID == "" {
				chat.BotID = id
				chat.Revision = revision
				migrated = append(migrated, chat)
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return false, err
		}
		for _, chat := range migrated {
			data, _ := json.Marshal(chat)
			if err := save(tx, "chats", chat.ID, data, revision, chat.AgentID, chat.ProjectID); err != nil {
				return false, err
			}
		}
		result = bot
		return changed || len(migrated) > 0, nil
	})
	return result, err
}

func (st *Store) CreateBot(bot Bot) (Bot, error) {
	var result Bot
	err := st.write(func(tx *sql.Tx, revision int64) (bool, error) {
		if bot.ID == "" {
			bot.ID = "bot-" + strings.ToLower(rand.Text())
		}
		if strings.HasPrefix(bot.ID, "mindwire-") {
			return false, invalid("use ensure to create Mindwire")
		}
		profile, _, err := botParents(tx, bot.AgentID, bot.ProjectID)
		if err != nil {
			return false, err
		}
		if err := st.checkBotEngine(profile); err != nil {
			return false, err
		}
		bot.Record = Record{ID: bot.ID, WorkspaceID: st.identity, Revision: revision, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano)}
		bot, err = normalizeBot(bot)
		if err != nil {
			return false, err
		}
		all, err := readBots(tx, -1)
		if err != nil {
			return false, err
		}
		for _, existing := range all {
			if existing.ID == bot.ID || (existing.ProjectID == bot.ProjectID && strings.EqualFold(existing.Name, bot.Name) && !existing.Archived) {
				if existing.ProjectID == bot.ProjectID && existing.AgentID == bot.AgentID && existing.Name == bot.Name && existing.Icon == bot.Icon && existing.Purpose == bot.Purpose && existing.Instructions == bot.Instructions && existing.Memory == bot.Memory && !existing.Archived {
					left, _ := json.Marshal(existing.Knowledge)
					right, _ := json.Marshal(bot.Knowledge)
					if string(left) == string(right) {
						result = existing
						return false, nil
					}
				}
				return false, ErrConflict
			}
		}
		result = bot
		return true, saveBot(tx, bot, revision)
	})
	return result, err
}

func (st *Store) UpdateBot(id string, patch BotPatch) (Bot, error) {
	var result Bot
	err := st.write(func(tx *sql.Tx, revision int64) (bool, error) {
		bot, err := readBot(tx, id)
		if err != nil {
			return false, err
		}
		if _, _, err := botParents(tx, bot.AgentID, bot.ProjectID); err != nil {
			return false, err
		}
		if patch.ExpectedRevision <= 0 || bot.Revision != patch.ExpectedRevision {
			return false, ErrConflict
		}
		if patch.Name != nil {
			bot.Name = *patch.Name
		}
		if patch.Icon != nil {
			bot.Icon = *patch.Icon
		}
		if patch.Purpose != nil {
			bot.Purpose = *patch.Purpose
		}
		if patch.Instructions != nil {
			bot.Instructions = *patch.Instructions
		}
		if patch.Memory != nil {
			bot.Memory = *patch.Memory
		}
		if patch.Knowledge != nil {
			bot.Knowledge = *patch.Knowledge
		}
		if patch.Archived != nil {
			bot.Archived = *patch.Archived
		}
		if patch.NotificationsMuted != nil {
			bot.NotificationsMuted = patch.NotificationsMuted
		}
		bot, err = normalizeBot(bot)
		if err != nil {
			return false, err
		}
		all, err := readBots(tx, -1)
		if err != nil {
			return false, err
		}
		for _, existing := range all {
			if existing.ID != bot.ID && existing.ProjectID == bot.ProjectID && !existing.Archived && !bot.Archived && strings.EqualFold(existing.Name, bot.Name) {
				return false, ErrConflict
			}
		}
		bot.Revision = revision
		result = bot
		return true, saveBot(tx, bot, revision)
	})
	return result, err
}

func validateBotChat(tx *sql.Tx, chat Chat) error {
	if chat.BotID == "" {
		return nil
	}
	bot, err := readBot(tx, chat.BotID)
	if err != nil {
		return invalid("the chat's bot does not exist")
	}
	if bot.ProjectID != chat.ProjectID {
		return invalid("a chat must stay in its bot's project")
	}
	return nil
}

func (st *Store) CreateBotChat(botID, chatID, title string) (Chat, error) {
	bot, err := st.Bot(botID)
	if err != nil {
		return Chat{}, err
	}
	if bot.Archived {
		return Chat{}, invalid("restore this bot before starting a chat")
	}
	if chatID == "" {
		chatID = "chat-" + strings.ToLower(rand.Text())
	}
	// A stable chat request is an ensure, not a rename. Native title/activity and
	// a user's later edits must not turn a lost-response retry into a conflict.
	if saved, _, _, lookupErr := st.ChatContext(chatID); lookupErr != nil {
		return Chat{}, lookupErr
	} else if saved != nil {
		if saved.BotID != bot.ID {
			return Chat{}, ErrConflict
		}
		return *saved, nil
	}
	chat := Chat{Record: Record{ID: chatID}, AgentID: bot.AgentID, ProjectID: bot.ProjectID, BotID: bot.ID, Title: title}
	data, _ := json.Marshal(chat)
	if err = st.Put("chats", chatID, data, nil); err != nil {
		return Chat{}, err
	}
	saved, _, _, err := st.ChatContext(chatID)
	if err != nil {
		return Chat{}, err
	}
	if saved == nil {
		return Chat{}, ErrNotFound
	}
	if saved.BotID != bot.ID {
		return Chat{}, ErrConflict
	}
	return *saved, nil
}

func (st *Store) BotChats(botID string) ([]Chat, error) {
	if _, err := st.Bot(botID); err != nil {
		return nil, err
	}
	snapshot, err := st.Snapshot(nil)
	if err != nil {
		return nil, err
	}
	chats := []Chat{}
	for _, chat := range snapshot.Chats {
		if chat.BotID == botID {
			chats = append(chats, chat)
		}
	}
	return chats, nil
}
