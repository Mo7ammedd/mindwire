package orchestrator

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/notify"
	"github.com/oblien/mindwire/packages/daemon/internal/session"
	"github.com/oblien/mindwire/packages/daemon/internal/stream"
)

type completionAdapter struct {
	*fakeAdapter
	produced, finish chan struct{}
	cancelled        bool
	calls            int
}

func (f *completionAdapter) RunStream(ctx context.Context, _ agent.TurnInput, emit agent.Emit) (agent.TurnResult, error) {
	f.calls++
	const text = "Output worth keeping"
	emit(agent.Event{Type: agent.EventText, Text: text})
	emit(agent.Event{Type: agent.EventResult, Result: &agent.ResultInfo{Text: text, Cancelled: f.cancelled}, Meta: map[string]any{"inputTokens": 12}})
	close(f.produced)
	select {
	case <-f.finish:
	case <-ctx.Done():
	}
	return agent.TurnResult{Text: text, Cancelled: f.cancelled}, nil
}

func TestCompletionWaitsForSaveAndRetainsOutputOnFailure(t *testing.T) {
	for _, mode := range []string{"saved", "failed", "cancelled", "resolve"} {
		t.Run(mode, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "state.json")
			store, err := session.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			f := &completionAdapter{fakeAdapter: &fakeAdapter{id: "completion-" + mode},
				produced: make(chan struct{}), finish: make(chan struct{}), cancelled: mode == "cancelled"}
			agent.Register(f)
			s := New(store, stream.New(), notify.Noop{}, t.TempDir(), f.ID())
			ag, _ := s.Resolve(f.ID())
			var run session.Run
			var ok bool
			if mode == "resolve" {
				run, ok = s.StartResolve(ag, StartTurnInput{ChatID: "chat", Message: "Do work"}, ResolveOptions{MaxIterations: 3})
			} else {
				run, ok = s.StartTurn(ag, StartTurnInput{ChatID: "chat", Message: "Do work"})
			}
			if !ok {
				t.Fatal("run was not admitted")
			}
			<-f.produced
			replay, _, _, cancel := s.SubscribeRun(run.ID, 0)
			cancel()
			for _, event := range replay {
				if event.Type == agent.EventResult {
					t.Error("native success reached the client before the completion write")
				}
			}
			if mode != "saved" {
				// A deterministic filesystem error, without relying on chmod/root
				// behavior or exhausting the host's real disk.
				if err := os.Mkdir(path+".tmp", 0700); err != nil {
					t.Fatal(err)
				}
			}
			close(f.finish)
			events := drainResolve(t, s, run.ID)
			s.Wait()
			completed, _ := store.GetRun(run.ID)
			want := "done"
			if mode != "saved" {
				want = "error"
			}
			if completed.Status != want || s.Busy(run.ChatID) || f.calls != 1 {
				t.Fatalf("terminal lifecycle: %+v busy=%v calls=%d", completed, s.Busy(run.ChatID), f.calls)
			}
			messages := store.Messages(run.ChatID)
			if len(messages) != 2 || messages[1].ID != completed.ReplyID || messages[1].Text != "Output worth keeping" {
				t.Fatalf("completion lost its reply: %+v messages=%+v", completed, messages)
			}
			results := 0
			for _, event := range events {
				if event.Type == agent.EventResult && event.Result != nil {
					results++
					if event.Result.IsError != (want == "error") {
						t.Errorf("incorrect terminal result: %+v", event.Result)
					}
					if mode != "resolve" && event.Meta["inputTokens"] != 12 {
						t.Errorf("completion dropped native usage metadata: %+v", event.Meta)
					}
				}
			}
			if results != 1 {
				t.Errorf("got %d terminal results, want 1", results)
			}
			_, notes, unsubscribe := s.notes.Subscribe()
			unsubscribe()
			if len(notes) != 1 || (notes[0].Condition == agent.Finished) != (want == "done") {
				t.Fatalf("incorrect completion notification: %+v", notes)
			}
			if mode != "saved" {
				if !strings.Contains(completed.Error, session.CompletionSaveError) {
					t.Fatalf("save failure was not explained: %+v", completed)
				}
				if mode == "resolve" {
					children := store.Children(run.ID)
					if len(children) != 1 || children[0].Status != "error" || completed.StopReason != "error" {
						t.Fatalf("resolve continued after failed save: %+v children=%+v", completed, children)
					}
				}
				if err := os.Remove(path + ".tmp"); err != nil {
					t.Fatal(err)
				}
				if err := store.Set("storage-recovered", "true"); err != nil {
					t.Fatal(err)
				}
			}
			reopened, err := session.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			durable, _ := reopened.GetRun(run.ID)
			if durable.Status != want || durable.ReplyID != completed.ReplyID || len(reopened.Messages(run.ChatID)) != 2 {
				t.Fatalf("terminal state/output did not survive storage recovery: %+v", durable)
			}
		})
	}
}
