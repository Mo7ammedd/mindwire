package mindwire

import (
	"path/filepath"
	"testing"
)

func TestBotsSharePersistedProfilesAcrossHarnessViews(t *testing.T) {
	c, err := New(Options{Agent: "codex", CWD: t.TempDir(), StatePath: filepath.Join(t.TempDir(), "state.json")})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if c.Health().BotsVersion < 2 {
		t.Fatal("bots capability missing")
	}
	if _, err := c.Workspace.Agents.Put("bot-agent", WorkspaceAgent{Name: "AI", AgentType: "codex"}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Workspace.Projects.Put("general-project", WorkspaceProject{Name: "General", Path: t.TempDir()}, nil); err != nil {
		t.Fatal(err)
	}
	master, err := c.Bots.Ensure("bot-agent", "general-project")
	if err != nil || !master.Bot.IsMaster {
		t.Fatalf("master: %+v %v", master, err)
	}
	created, err := c.Bots.Create(Bot{AgentID: "bot-agent", ProjectID: "general-project", Name: "Study Coach", Icon: "lilac-bloom", Purpose: "Teach biology", Instructions: "Ask questions before explaining"})
	if err != nil {
		t.Fatal(err)
	}
	other := c.WithAgent("codex")
	bot, err := other.Bots.Get(created.Bot.ID)
	if err != nil || bot.Instructions != created.Bot.Instructions || bot.Icon != "lilac-bloom" {
		t.Fatalf("shared bot: %+v %v", bot, err)
	}
	memory := "The user is learning photosynthesis."
	updated, err := other.Bots.Update(bot.ID, BotEdit{ExpectedRevision: bot.Revision, Memory: &memory})
	if err != nil || updated.Bot.Memory != memory || updated.Bot.Icon != bot.Icon {
		t.Fatalf("memory: %+v %v", updated, err)
	}
	chat, err := c.Bots.CreateChat(bot.ID, "study-thread", "First lesson")
	if err != nil || chat.BotID != bot.ID {
		t.Fatalf("chat membership: %+v %v", chat, err)
	}
	chats, err := other.Bots.Chats(bot.ID)
	if err != nil || len(chats) != 1 || chats[0].ID != chat.ID {
		t.Fatalf("history: %+v %v", chats, err)
	}
}
