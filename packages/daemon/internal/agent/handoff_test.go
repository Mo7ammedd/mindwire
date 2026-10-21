package agent

import (
	"context"
	"errors"
	"testing"
)

type handoffSnapshotAdapter struct {
	Adapter
	calls        int
	changed      bool
	recordedRead bool
}

func (a *handoffSnapshotAdapter) HistoryRevision(HistoryQuery) (string, error) {
	a.calls++
	if a.changed && a.calls > 1 {
		return "new", nil
	}
	return "original", nil
}
func (a *handoffSnapshotAdapter) History(q HistoryQuery) ([]Message, error) {
	a.recordedRead = len(q.Recorded) > 0
	return nil, nil
}

func TestHandoffSnapshotRejectsConcurrentMutationAndKeepsEmptyNativeState(t *testing.T) {
	for _, changed := range []bool{false, true} {
		a := &handoffSnapshotAdapter{changed: changed}
		got, err := ReadHandoffSnapshot(context.Background(), a, HistoryQuery{Recorded: []Message{{Role: "user", Text: "discarded"}}}, true)
		if a.recordedRead {
			t.Fatal("display merge can resurrect discarded turns")
		}
		if changed {
			if !errors.Is(err, ErrHandoffHistoryChanged) {
				t.Fatalf("inconsistent native snapshot accepted: %+v %v", got, err)
			}
		} else if err != nil || !got.Available || len(got.Messages) != 0 {
			t.Fatalf("authoritative empty became unavailable: %+v %v", got, err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := ReadHandoffSnapshot(ctx, &handoffSnapshotAdapter{}, HistoryQuery{}, true); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled export: %v", err)
	}
}
