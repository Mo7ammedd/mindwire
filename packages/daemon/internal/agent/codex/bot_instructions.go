package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/proc"
	"github.com/oblien/mindwire/packages/daemon/internal/toolchain"
)

type nativeInstructionConfig struct {
	Developer string `json:"developer_instructions"`
	Base      string `json:"base_instructions"`
	File      string `json:"model_instructions_file"`
	Catalog   string `json:"model_catalog_json"`
	Model     string `json:"model"`
}

// Early bot builds put the profile in baseInstructions. Codex persists that field
// in session metadata and resumes it even when the caller stops sending overrides.
// Repair only that recognizable legacy profile via the native resume API, using
// the installed CLI's own prompt. Never edit rollouts or replace user overrides.
func (a *appServer) restoreBotBaseInstructions(ctx context.Context, cfg nativeInstructionConfig) error {
	if a.developerInstructions == "" || a.instructions != "" || a.resumeID == "" {
		return nil
	}
	path := findRollout(configBase(), a.resumeID)
	if path == "" {
		return nil
	}
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("read saved bot instructions: %w", err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(io.LimitReader(file, 2<<20))
	scanner.Buffer(make([]byte, 64<<10), 2<<20)
	if !scanner.Scan() {
		return scanner.Err()
	}
	var header struct {
		Type    string `json:"type"`
		Payload struct {
			Base struct {
				Text string `json:"text"`
			} `json:"base_instructions"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &header); err != nil {
		return fmt.Errorf("read saved bot header: %w", err)
	}
	text := header.Payload.Base.Text
	if header.Type != "session_meta" || !strings.HasPrefix(text, "You are an assistant inside Mindwire on the user's phone or desktop.") ||
		!strings.Contains(text, "\nCurrent saved bot profile:\n") {
		return nil
	}

	if cfg.Base != "" {
		a.instructions = cfg.Base
		return nil
	}
	if cfg.File != "" {
		data, err := readInstructionFile(cfg.File, a.cwd)
		if err != nil {
			return err
		}
		a.instructions = string(data)
		return nil
	}
	var data []byte
	if cfg.Catalog != "" {
		data, err = readInstructionFile(cfg.Catalog, a.cwd)
	} else {
		readCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		cmd := toolchain.CommandContext(readCtx, "codex", "debug", "models")
		proc.Group(cmd)
		cmd.Dir = a.cwd
		cmd.Env = toolchain.Environment()
		for key, value := range a.env {
			cmd.Env = append(cmd.Env, key+"="+value)
		}
		data, err = cmd.Output()
	}
	if err != nil {
		return fmt.Errorf("restore native Codex instructions: %w", err)
	}
	model := agent.FirstNonEmpty(a.model, cfg.Model)
	var catalog struct {
		Models []struct {
			Slug     string `json:"slug"`
			Base     string `json:"base_instructions"`
			Messages struct {
				Template string `json:"instructions_template"`
			} `json:"model_messages"`
		} `json:"models"`
	}
	if err := json.Unmarshal(data, &catalog); err != nil {
		return fmt.Errorf("read native Codex instructions: %w", err)
	}
	for _, entry := range catalog.Models {
		if entry.Slug == model {
			a.instructions = agent.FirstNonEmpty(entry.Messages.Template, entry.Base)
			if a.instructions != "" {
				return nil
			}
		}
	}
	return fmt.Errorf("could not restore native instructions for this older bot conversation with model %q; start a new conversation to use its native defaults", model)
}

func readInstructionFile(path, cwd string) ([]byte, error) {
	if !filepath.IsAbs(path) {
		path = filepath.Join(cwd, path)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("read native instruction configuration: %w", err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, (8<<20)+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 8<<20 {
		return nil, fmt.Errorf("native instruction configuration exceeds 8 MiB")
	}
	if strings.TrimSpace(string(data)) == "" {
		return nil, fmt.Errorf("native instruction configuration is empty")
	}
	return data, nil
}

// Codex 0.153.x can keep an old developer message on the first cold-resumed turn
// (openai/codex#19045). Keep its native baseline current and append an update only
// when the saved model context does not already contain this profile. Inspect a
// bounded tail, never rewrite history or expose developer context as a user message.
func botContextNeedsUpdate(threadID, instructions string) bool {
	if threadID == "" || instructions == "" {
		return false
	}
	path := findRollout(configBase(), threadID)
	file, err := os.Open(path)
	if err != nil {
		return true
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return true
	}
	const limit int64 = 512 << 10
	start := max(int64(0), info.Size()-limit)
	if _, err = file.Seek(start, io.SeekStart); err != nil {
		return true
	}
	data, err := io.ReadAll(io.LimitReader(file, limit))
	if err != nil {
		return true
	}
	lines := strings.Split(string(data), "\n")
	if start > 0 && len(lines) > 0 {
		lines = lines[1:]
	}
	for i := len(lines) - 1; i >= 0; i-- {
		var envelope rolloutEnvelope
		if json.Unmarshal([]byte(lines[i]), &envelope) != nil {
			continue
		}
		if envelope.Type == "compacted" {
			return true
		}
		if envelope.Type != "response_item" {
			continue
		}
		var message struct {
			Role    string `json:"role"`
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
		}
		if json.Unmarshal(envelope.Payload, &message) != nil || message.Role != "developer" {
			continue
		}
		for _, part := range message.Content {
			if strings.Contains(part.Text, "\nCurrent saved bot profile:\n") {
				return !strings.Contains(part.Text, instructions)
			}
		}
	}
	return true
}
