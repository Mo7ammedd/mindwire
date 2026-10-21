package opencode

import (
	"context"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func TestHandoffNativeEmptyAndRevertedSessionsRemainAuthoritative(t *testing.T) {
	db := nativeFixture(t)
	cwd := t.TempDir()
	fixtureSession(t, db, "ses_history", cwd, "Existing")
	q := agent.HistoryQuery{SessionID: "ses_history", CWD: cwd, Recorded: []agent.Message{{Role: "user", Text: "Discarded recorded future"}}}
	check := func(count int) {
		t.Helper()
		history, err := (adapter{}).ExportHandoff(context.Background(), q)
		if err != nil || !history.Available || len(history.Messages) != count {
			t.Fatalf("native snapshot: %+v %v", history, err)
		}
	}
	check(0)
	fixtureMessage(t, db, "msg_001", "user", 1000, map[string]any{"id": "prt_001", "type": "text", "text": "Original"})
	check(1)
	fixtureExec(t, db, `UPDATE session SET revert='{"messageID":"msg_001"}' WHERE id='ses_history'`)
	check(0)
	q.SessionID = "ses_missing"
	history, err := (adapter{}).ExportHandoff(context.Background(), q)
	if err != nil || history.Available {
		t.Fatalf("missing native session must permit recorded fallback: %+v %v", history, err)
	}
}
