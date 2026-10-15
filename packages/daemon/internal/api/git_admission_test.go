package api

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/orchestrator"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"github.com/oblien/mindwire/packages/daemon/internal/workspaceexec"
)

type gitWorkingAdapter struct {
	resolveFakeAdapter
	started chan struct{}
}

func (f *gitWorkingAdapter) RunStream(ctx context.Context, _ agent.TurnInput, _ agent.Emit) (agent.TurnResult, error) {
	close(f.started)
	<-ctx.Done()
	return agent.TurnResult{}, ctx.Err()
}

func TestGitHTTPNonDisruptiveOperationsDuringOrdinaryWork(t *testing.T) {
	for _, work := range []string{"command", "terminal", "parent-terminal", "agent", "other-project-agent"} {
		t.Run(work, func(t *testing.T) {
			t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
			t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
			fake := &gitWorkingAdapter{resolveFakeAdapter: resolveFakeAdapter{id: "git-stage-active-agent"}, started: make(chan struct{})}
			if work == "agent" || work == "other-project-agent" {
				agent.Register(fake)
			}
			h, a, dir := gitHTTPFixture(t)
			apiGit(t, "-C", dir, "config", "user.email", "fixture@example.invalid")
			remote := t.TempDir()
			apiGit(t, "init", "--bare", remote)
			apiGit(t, "-C", dir, "remote", "set-url", "origin", remote)
			workDir, chatID := dir, "chat"
			if work == "parent-terminal" {
				workDir = filepath.Dir(dir)
			} else if work == "other-project-agent" {
				var err error
				workDir, err = filepath.EvalSymlinks(t.TempDir())
				if err != nil {
					t.Fatal(err)
				}
				chatID = "other-chat"
				body, err := json.Marshal(map[string]any{
					"projects": []map[string]string{{"id": "other-project", "name": "Other", "path": workDir}},
					"chats":    []map[string]string{{"id": chatID, "agentId": "profile", "projectId": "other-project", "title": "Other work"}},
				})
				if err != nil {
					t.Fatal(err)
				}
				if got := serve(t, h, "POST", "/workspace/import", string(body)); got.Code != 200 {
					t.Fatalf("import other project: %d %s", got.Code, got.Body.String())
				}
			}
			path := filepath.Join(dir, "tracked")
			if err := os.WriteFile(path, []byte("base\n"), 0600); err != nil {
				t.Fatal(err)
			}
			apiGit(t, "-C", dir, "add", "tracked")
			apiGit(t, "-C", dir, "-c", "user.email=fixture@example.invalid", "commit", "-m", "Base")
			if err := os.WriteFile(path, []byte("working changes\n"), 0600); err != nil {
				t.Fatal(err)
			}
			switch work {
			case "command":
				ctx, cancel := context.WithCancel(context.Background())
				started, done := make(chan struct{}, 1), make(chan struct{})
				go func() {
					defer close(done)
					_, _ = a.execution.Exec(ctx, workspaceexec.ExecRequest{
						Argv: []string{"sh", "-c", "printf ready; exec sleep 60"}, Directory: dir,
					}, func(_ string, _ []byte) {
						select {
						case started <- struct{}{}:
						default:
						}
					})
				}()
				t.Cleanup(func() { cancel(); <-done })
				select {
				case <-started:
				case <-time.After(5 * time.Second):
					t.Fatal("command did not start")
				}
			case "terminal", "parent-terminal":
				t.Setenv("SHELL", "/bin/sh")
				terminal, err := a.execution.Terminals.Open(workspaceexec.TerminalRequest{
					ID: "git-stage-terminal", Directory: workDir, Columns: 80, Rows: 24,
				})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = a.execution.Terminals.Remove(terminal.ID) })
			case "agent", "other-project-agent":
				adapter, ok := a.sup.Resolve(fake.ID())
				if !ok {
					t.Fatal("could not resolve test adapter")
				}
				run, err := a.sup.StartTurnChecked(adapter, orchestrator.StartTurnInput{ChatID: chatID, Message: "Work", CWD: workDir})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { a.sup.Cancel(run.ID); a.sup.Wait() })
				select {
				case <-fake.started:
				case <-time.After(5 * time.Second):
					t.Fatal("agent did not start")
				}
			}
			if !a.BusyPath(workDir) {
				t.Fatal("fixture has no active work")
			}
			for _, action := range []string{"stage", "unstage"} {
				body := `{"id":"` + action + `","action":"` + action + `","paths":["tracked"]}`
				got := serve(t, h, "POST", "/workspace/projects/project/git/operations", body)
				var operation registry.GitOperation
				if got.Code != 202 || json.Unmarshal(got.Body.Bytes(), &operation) != nil {
					t.Fatalf("%s during %s: %d %s", action, work, got.Code, got.Body.String())
				}
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				result, err := a.gitJobs.Wait(ctx, operation.ID)
				cancel()
				if err != nil || result.Status != "succeeded" {
					t.Fatalf("%s result: %+v %v", action, result, err)
				}
				staged := apiGit(t, "-C", dir, "diff", "--cached", "--name-only")
				if (action == "stage" && staged != "tracked") || (action == "unstage" && staged != "") {
					t.Fatalf("%s index: %q", action, staged)
				}
				data, err := os.ReadFile(path)
				if err != nil || string(data) != "working changes\n" {
					t.Fatalf("%s changed working files: %q %v", action, data, err)
				}
				if !a.BusyPath(workDir) {
					t.Fatalf("%s interrupted active work", action)
				}
			}
			// A commit records the staged snapshot, leaving newer edits and active
			// work alone, even when an idle terminal belongs to a parent directory.
			apiGit(t, "-C", dir, "add", "tracked")
			if err := os.WriteFile(path, []byte("newer unstaged changes\n"), 0600); err != nil {
				t.Fatal(err)
			}
			got := serve(t, h, "POST", "/workspace/projects/project/git/operations", `{"id":"commit","action":"commit","message":"Save staged changes"}`)
			var operation registry.GitOperation
			if got.Code != 202 || json.Unmarshal(got.Body.Bytes(), &operation) != nil {
				t.Fatalf("commit during %s: %d %s", work, got.Code, got.Body.String())
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			result, err := a.gitJobs.Wait(ctx, operation.ID)
			cancel()
			if err != nil || result.Status != "succeeded" {
				t.Fatalf("commit result: %+v %v", result, err)
			}
			if got := apiGit(t, "-C", dir, "show", "HEAD:tracked"); got != "working changes" {
				t.Fatalf("commit included unstaged work: %q", got)
			}
			data, err := os.ReadFile(path)
			if err != nil || string(data) != "newer unstaged changes\n" {
				t.Fatalf("commit changed working files: %q %v", data, err)
			}
			if !a.BusyPath(workDir) {
				t.Fatal("commit interrupted active work")
			}
			for _, action := range []string{"push", "fetch"} {
				body := `{"id":"` + action + `","action":"` + action + `"}`
				got := serve(t, h, "POST", "/workspace/projects/project/git/operations", body)
				if got.Code != 202 {
					t.Fatalf("%s during %s: %d %s", action, work, got.Code, got.Body.String())
				}
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				result, err := a.gitJobs.Wait(ctx, action)
				cancel()
				if err != nil || result.Status != "succeeded" {
					t.Fatalf("%s result: %+v %v", action, result, err)
				}
				data, err := os.ReadFile(path)
				if err != nil || string(data) != "newer unstaged changes\n" || !a.BusyPath(workDir) {
					t.Fatalf("%s changed working files or interrupted active work: %q %v", action, data, err)
				}
			}
			branch := apiGit(t, "-C", dir, "symbolic-ref", "HEAD")
			if apiGit(t, "-C", remote, "rev-parse", branch) != apiGit(t, "-C", dir, "rev-parse", "HEAD") {
				t.Fatal("push did not publish the committed snapshot")
			}
			if work == "other-project-agent" {
				if a.BusyPath(dir) {
					t.Fatal("unrelated project remains busy")
				}
				return
			}
			got = serve(t, h, "POST", "/workspace/projects/project/git/operations", `{"id":"discard","action":"discard","paths":["tracked"]}`)
			if got.Code != 409 || strings.Contains(got.Body.String(), "record changed") {
				t.Fatalf("discard must retain a clear active-work guard: %d %s", got.Code, got.Body.String())
			}
			got = serve(t, h, "POST", "/workspace/projects/project/git/pull", `{}`)
			if got.Code != 409 {
				t.Fatalf("pull must retain its active-work guard: %d %s", got.Code, got.Body.String())
			}
		})
	}
}

func TestGitHTTPNonDisruptiveOperationsRespectProjectSyncReservation(t *testing.T) {
	h, a, dir := gitHTTPFixture(t)
	if err := a.registry.ReserveSync("sync", dir); err != nil {
		t.Fatal(err)
	}
	for _, action := range []string{"stage", "unstage", "commit", "push", "fetch"} {
		body := `{"id":"` + action + `","action":"` + action + `","paths":["tracked"]}`
		if action == "commit" {
			body = `{"id":"commit","action":"commit","message":"Blocked by sync"}`
		} else if action == "push" || action == "fetch" {
			body = `{"id":"` + action + `","action":"` + action + `"}`
		}
		got := serve(t, h, "POST", "/workspace/projects/project/git/operations", body)
		if got.Code != 409 || !strings.Contains(got.Body.String(), "synchronization") {
			t.Fatalf("%s during sync: %d %s", action, got.Code, got.Body.String())
		}
	}
}

func TestGitHTTPPushAllowsNewAgentWorkButKeepsGitAndProjectReservations(t *testing.T) {
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	fake := &gitWorkingAdapter{resolveFakeAdapter: resolveFakeAdapter{id: "git-push-new-agent"}, started: make(chan struct{})}
	agent.Register(fake)
	h, a, dir := gitHTTPFixture(t)
	body, _ := json.Marshal(map[string]any{
		"agents": []map[string]string{{"id": "push-profile", "name": "Test agent", "agentType": fake.ID()}},
		"chats":  []map[string]string{{"id": "push-chat", "agentId": "push-profile", "projectId": "project", "title": "Work during push"}},
	})
	if got := serve(t, h, "POST", "/workspace/import", string(body)); got.Code != 200 {
		t.Fatal(got.Body.String())
	}
	apiGit(t, "-C", dir, "config", "user.email", "fixture@example.invalid")
	apiGit(t, "-C", dir, "commit", "--allow-empty", "-m", "Committed snapshot")
	remote := t.TempDir()
	apiGit(t, "init", "--bare", remote)
	apiGit(t, "-C", dir, "remote", "set-url", "origin", remote)
	hook := "#!/bin/sh\n: > .git/push-started\nwhile [ ! -f .git/push-release ]; do sleep 0.02; done\n"
	if err := os.WriteFile(filepath.Join(dir, ".git/hooks/pre-push"), []byte(hook), 0700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.WriteFile(filepath.Join(dir, ".git/push-release"), nil, 0600) })
	request := `{"id":"slow-push","action":"push"}`
	if got := serve(t, h, "POST", "/workspace/projects/project/git/operations", request); got.Code != 202 {
		t.Fatalf("start push: %d %s", got.Code, got.Body.String())
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(dir, ".git/push-started")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("push hook did not start")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if got := serve(t, h, "POST", "/workspace/projects/project/git/operations", request); got.Code != 202 {
		t.Fatal("a push retry did not return the original operation")
	}
	if got := serve(t, h, "POST", "/workspace/projects/project/git/push", `{}`); got.Code != 409 {
		t.Fatal("a second push bypassed the repository reservation")
	}
	if err := a.registry.ReserveSync("blocked-sync", dir); !errors.Is(err, registry.ErrConflict) {
		t.Fatalf("project transfer bypassed push reservation: %v", err)
	}
	if err := a.registry.CheckProjectPath(dir); !errors.Is(err, registry.ErrConflict) {
		t.Fatalf("project mutation bypassed push reservation: %v", err)
	}
	// Creating chat membership is metadata-only and must work during a transfer.
	newChat := `{"record":{"agentId":"push-profile","projectId":"project","title":"New chat during push"}}`
	if got := serve(t, h, "PUT", "/workspace/chats/new-chat", newChat); got.Code != 200 {
		t.Fatalf("create chat during push: %d %s", got.Code, got.Body.String())
	}
	got := serve(t, h, "POST", "/turns?agent="+fake.ID(), `{"chatId":"push-chat","message":"Continue working"}`)
	if got.Code != 200 && got.Code != 202 {
		t.Fatalf("agent start during push: %d %s", got.Code, got.Body.String())
	}
	var run struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(got.Body.Bytes(), &run); err != nil || run.ID == "" {
		t.Fatalf("invalid agent response: %s", got.Body.String())
	}
	t.Cleanup(func() { a.sup.Cancel(run.ID); a.sup.Wait() })
	select {
	case <-fake.started:
	case <-time.After(5 * time.Second):
		t.Fatal("agent was accepted but did not start")
	}
	if _, err := a.registry.InteractionCWD("push-chat", fake.ID(), dir); err != nil {
		t.Fatalf("agent interaction during push: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".git/push-release"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result, err := a.gitJobs.Wait(ctx, "slow-push")
	if err != nil || result.Status != "succeeded" || !a.sup.Busy("push-chat") {
		t.Fatalf("push and agent did not remain independent: %+v %v", result, err)
	}
}
