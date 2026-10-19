package session

import (
	"fmt"
	"strings"
)

const CompletionSaveError = "Mindwire could not save this turn to disk. Its output is retained in this running daemon and will be retried on the next state write. Fix storage before restarting to avoid losing it."

// CompleteRun commits the terminal status and transcript together. Unlike a
// rejected admission, a completed native turn cannot be rolled back or safely
// rerun. If disk writes fail, retain its output and an explicit terminal error
// in memory; the next successful state write includes both. The caller must
// report the error instead of sending a success result or notification.
func (st *Store) CompleteRun(run Run, messages []Message) (Run, error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	if run.Status == "running" || run.Status == "" {
		return run, fmt.Errorf("completion requires a terminal run status")
	}
	index := len(st.s.Runs)
	for i, previous := range st.s.Runs {
		if previous.ID == run.ID {
			run.Inputs = previous.Inputs
			index = i
			break
		}
	}
	if index == len(st.s.Runs) {
		st.s.Runs = append(st.s.Runs, run)
	} else {
		st.s.Runs[index] = run
	}
	st.replaceTurnMessages(messages)
	st.touchHistory(run.ChatID)
	if run.Status == "cancelled" {
		st.closeCancelledQuestions(map[string]bool{run.ID: true})
	}
	if err := st.save(); err != nil {
		run.Status = "error"
		if !strings.Contains(run.Error, CompletionSaveError) {
			if run.Error != "" {
				run.Error += "\n\n"
			}
			run.Error += CompletionSaveError
		}
		if run.Kind == "resolve" {
			run.StopReason = "error"
		}
		st.s.Runs[index] = run
		st.closeCancelledQuestions(map[string]bool{run.ID: true})
		return run, err
	}
	return run, nil
}
