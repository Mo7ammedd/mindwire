// Package skills validates portable SKILL.md documents and prepares a private,
// turn-scoped bundle. It contains no product presets or global harness config.
package skills

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"go.yaml.in/yaml/v3"
)

type Definition struct {
	Name        string `json:"name" yaml:"name"`
	Description string `json:"description" yaml:"description"`
	Markdown    string `json:"-" yaml:"-"`
}

var namePattern = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// Parse accepts the portable Agent Skills fields. Native permission overrides,
// hooks and process directives are not portable workflow instructions.
func Parse(raw string) (Definition, error) {
	raw = strings.ReplaceAll(strings.TrimSpace(raw), "\r\n", "\n")
	if len(raw) > 32768 || strings.ContainsRune(raw, 0) || !strings.HasPrefix(raw, "---\n") {
		return Definition{}, fmt.Errorf("a skill needs SKILL.md frontmatter and must fit within 32 KiB")
	}
	header, body, ok := strings.Cut(raw[4:], "\n---\n")
	if !ok || strings.TrimSpace(body) == "" {
		return Definition{}, fmt.Errorf("a skill needs frontmatter followed by workflow instructions")
	}
	if strings.Contains(body, "!`") {
		return Definition{}, fmt.Errorf("portable skills cannot run dynamic shell substitutions; use the harness's command tools")
	}
	var fields struct {
		Name          string            `yaml:"name"`
		Description   string            `yaml:"description"`
		License       string            `yaml:"license"`
		Compatibility string            `yaml:"compatibility"`
		Metadata      map[string]string `yaml:"metadata"`
	}
	decoder := yaml.NewDecoder(strings.NewReader(header))
	decoder.KnownFields(true)
	if err := decoder.Decode(&fields); err != nil {
		return Definition{}, fmt.Errorf("invalid portable skill frontmatter: %w", err)
	}
	if len(fields.Name) > 64 || !namePattern.MatchString(fields.Name) || strings.TrimSpace(fields.Description) == "" || len(fields.Description) > 1024 || strings.ContainsAny(fields.Description, "\r\n") {
		return Definition{}, fmt.Errorf("a skill needs a lowercase hyphenated name and a short single-line description")
	}
	return Definition{Name: fields.Name, Description: fields.Description, Markdown: raw + "\n"}, nil
}

func ParseAll(documents []string) ([]Definition, error) {
	if len(documents) > 16 {
		return nil, fmt.Errorf("a bot supports at most 16 skills")
	}
	out := make([]Definition, 0, len(documents))
	seen, size := map[string]bool{}, 0
	for _, document := range documents {
		definition, err := Parse(document)
		if err != nil {
			return nil, err
		}
		if seen[definition.Name] {
			return nil, fmt.Errorf("duplicate skill name %q", definition.Name)
		}
		seen[definition.Name] = true
		size += len(definition.Markdown)
		out = append(out, definition)
	}
	if size > 131072 {
		return nil, fmt.Errorf("bot skills exceed 128 KiB")
	}
	return out, nil
}

// Materialize writes only validated documents into an owned temporary directory.
// Every harness reads the exact same files. Cleanup belongs to the requesting turn.
func Materialize(definitions []Definition) (string, func(), error) {
	if len(definitions) == 0 {
		return "", func() {}, nil
	}
	root, err := os.MkdirTemp("", "mindwire-bot-skills-")
	if err != nil {
		return "", func() {}, err
	}
	cleanup := func() { _ = os.RemoveAll(root) }
	write := func(relative string, contents []byte) error {
		path := filepath.Join(root, relative)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return err
		}
		return os.WriteFile(path, contents, 0600)
	}
	manifest, _ := json.Marshal(map[string]string{"name": "mindwire-bot-skills", "version": "1.0.0", "description": "Skills assigned to this bot for the current turn."})
	if err = write(".claude-plugin/plugin.json", manifest); err == nil {
		for _, definition := range definitions {
			if !namePattern.MatchString(definition.Name) || len(definition.Name) > 64 {
				err = fmt.Errorf("invalid skill directory name")
				break
			}
			if err = write(filepath.Join("skills", definition.Name, "SKILL.md"), []byte(definition.Markdown)); err != nil {
				break
			}
		}
	}
	if err != nil {
		cleanup()
		return "", func() {}, err
	}
	return root, cleanup, nil
}
