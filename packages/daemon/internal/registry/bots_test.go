package registry

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
)

func TestGeneralBotsMigrationPersistenceAndIndependentChats(t *testing.T) {
	path := filepath.Join(t.TempDir(), "workspace.db")
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = st.Import(fixture()); err != nil {
		t.Fatal(err)
	}
	master, err := st.EnsureMaster("agent", "project")
	if err != nil {
		t.Fatal(err)
	}
	first := snapshot(t, st, nil)
	if !master.IsMaster || first.Chats[0].BotID != master.ID || len(first.Bots) != 1 {
		t.Fatalf("migration: %+v", first)
	}
	if _, err = st.EnsureMaster("agent", "project"); err != nil {
		t.Fatal(err)
	}
	if snapshot(t, st, nil).Revision != first.Revision {
		t.Fatal("repeated setup changed state")
	}
	bot, err := st.CreateBot(Bot{AgentID: "agent", ProjectID: "project", Name: "Writing Partner", Icon: "mint-pebble", Purpose: "Help me write", Instructions: "Use clear prose", Memory: "Prefer short sentences", Knowledge: []BotKnowledge{{ID: "style", Title: "Style guide", Content: "Use active voice."}}})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := st.CreateBotChat(bot.ID, "bot-chat", "Draft an article")
	if err != nil {
		t.Fatal(err)
	}
	if chat.BotID != bot.ID {
		t.Fatal("new chat lost its bot")
	}
	if _, err := st.CreateBotChat(master.ID, chat.ID, chat.Title); !errors.Is(err, ErrConflict) {
		t.Fatalf("reused another bot's chat: %v", err)
	}
	duplicate, err := st.CreateBotChat(bot.ID, "bot-chat", "Draft an article")
	if err != nil || duplicate.ID != chat.ID {
		t.Fatalf("retry: %+v %v", duplicate, err)
	}
	chats, err := st.BotChats(bot.ID)
	if err != nil || len(chats) != 1 {
		t.Fatalf("bot history: %+v %v", chats, err)
	}
	instructions := "Use clear prose and ask about the audience first."
	icon := "lilac-bloom"
	updated, err := st.UpdateBot(bot.ID, BotPatch{ExpectedRevision: bot.Revision, Instructions: &instructions, Icon: &icon})
	if err != nil {
		t.Fatal(err)
	}
	if updated.Memory != bot.Memory || len(updated.Knowledge) != 1 || updated.Icon != icon {
		t.Fatal("prompt edit overwrote knowledge or memory")
	}
	if _, err = st.UpdateBot(bot.ID, BotPatch{ExpectedRevision: bot.Revision, Instructions: &instructions}); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale edit: %v", err)
	}
	archived := true
	updated, err = st.UpdateBot(bot.ID, BotPatch{ExpectedRevision: updated.Revision, Archived: &archived})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = st.CreateBotChat(bot.ID, "archived-chat", ""); !errors.Is(err, ErrInvalid) {
		t.Fatalf("archived bot started chat: %v", err)
	}
	if chats, _ = st.BotChats(bot.ID); len(chats) != 1 {
		t.Fatal("archive removed history")
	}
	delta := snapshot(t, st, &first.Revision)
	if len(delta.Bots) != 1 || delta.Bots[0].ID != bot.ID {
		t.Fatalf("delta lost bot: %+v", delta.Bots)
	}
	st.Close()
	st, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	restored, err := st.Bot(bot.ID)
	if err != nil || restored.Memory != bot.Memory || restored.Instructions != instructions || !restored.Archived || restored.Icon != icon {
		t.Fatalf("restart: %+v %v", restored, err)
	}
	if chats, _ = st.BotChats(bot.ID); len(chats) != 1 {
		t.Fatal("restart lost chat")
	}
}

func TestBotIconCatalogValidationAndAutomaticReset(t *testing.T) {
	for _, color := range []string{"mint", "amber", "lilac", "blue", "peach", "rose", "olive"} {
		for _, shape := range []string{"pebble", "squircle", "sprout", "bean", "bloom", "spark", "drop", "arch"} {
			if !validBotIcon(color + "-" + shape) {
				t.Fatalf("missing template %s-%s", color, shape)
			}
		}
	}
	st := openTest(t)
	if err := st.Import(fixture()); err != nil {
		t.Fatal(err)
	}
	master, err := st.EnsureMaster("agent", "project")
	if err != nil {
		t.Fatal(err)
	}
	for _, icon := range []string{"orange-pebble", "mint-missing", "blue-spark-extra", "https://example.com/avatar.png"} {
		if _, err := st.UpdateBot(master.ID, BotPatch{ExpectedRevision: master.Revision, Icon: &icon}); !errors.Is(err, ErrInvalid) {
			t.Fatalf("accepted invalid icon %q: %v", icon, err)
		}
	}
	icon := "blue-spark"
	master, err = st.UpdateBot(master.ID, BotPatch{ExpectedRevision: master.Revision, Icon: &icon})
	if err != nil || master.Icon != icon {
		t.Fatalf("master icon: %+v %v", master, err)
	}
	icon = ""
	master, err = st.UpdateBot(master.ID, BotPatch{ExpectedRevision: master.Revision, Icon: &icon})
	if err != nil || master.Icon != "" {
		t.Fatalf("automatic icon: %+v %v", master, err)
	}
}

func TestBotsPreserveDeveloperChatsAndRejectCrossProjectMembership(t *testing.T) {
	st := openTest(t)
	batch := fixture()
	batch.Projects = append(batch.Projects, Project{Record: Record{ID: "developer"}, Name: "Code", Path: "/work/code"})
	batch.Chats = append(batch.Chats, Chat{Record: Record{ID: "dev-chat"}, AgentID: "agent", ProjectID: "developer", Title: "Code"})
	if err := st.Import(batch); err != nil {
		t.Fatal(err)
	}
	master, err := st.EnsureMaster("agent", "project")
	if err != nil {
		t.Fatal(err)
	}
	dev, _, _, err := st.ChatContext("dev-chat")
	if err != nil || dev.BotID != "" {
		t.Fatal("General migrated Developer chat")
	}
	bad := Chat{Record: Record{ID: "bad"}, AgentID: "agent", ProjectID: "developer", BotID: master.ID, Title: "Bad"}
	data, _ := json.Marshal(bad)
	if err = st.Put("chats", bad.ID, data, nil); !errors.Is(err, ErrInvalid) {
		t.Fatalf("cross-project membership: %v", err)
	}
	chat, _, _, _ := st.ChatContext("chat")
	revision := chat.Revision
	if err = st.Put("chats", chat.ID, []byte(`{"agentId":"agent","projectId":"project","title":"Renamed by an old client"}`), &revision); err != nil {
		t.Fatal(err)
	}
	chat, _, _, _ = st.ChatContext("chat")
	if chat.BotID != master.ID {
		t.Fatal("old-client rename removed bot membership")
	}
	archived := true
	if _, err = st.UpdateBot(master.ID, BotPatch{ExpectedRevision: master.Revision, Archived: &archived}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("archived Mindwire: %v", err)
	}
}
