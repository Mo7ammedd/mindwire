package shortcuts

import (
	"context"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

// Publication is a provider-independent plan, not a deployment receipt. The
// authenticated owner client chooses its hosting adapter and records publicUrl
// only after the provider confirms success. Provider credentials never enter Go.
type Publication struct {
	App       registry.AppShortcut `json:"app"`
	Kind      string               `json:"kind"`
	Port      int                  `json:"port,omitempty"`
	Directory string               `json:"directory,omitempty"`
}

func (s *Service) PreparePublication(ctx context.Context, id string) (Publication, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	app, err := s.db.App(id)
	plan := Publication{App: app}
	if err != nil {
		return plan, err
	}
	if app.Archived || app.Automation {
		return plan, fmt.Errorf("%w: only active web apps can be published", registry.ErrInvalid)
	}
	root, err := s.db.AppDirectory(app)
	if err != nil {
		return plan, err
	}
	if app.StaticDirectory == "" {
		u, err := url.Parse(app.URL)
		if err != nil || !registry.LocalAppURL(app.URL) {
			return plan, fmt.Errorf("%w: save a local app URL or a static build directory first", registry.ErrInvalid)
		}
		portText := u.Port()
		if portText == "" {
			portText = "80"
			if u.Scheme == "https" {
				portText = "443"
			}
		}
		port, err := strconv.Atoi(portText)
		if err != nil || port < 1 || port > 65535 {
			return plan, fmt.Errorf("%w: invalid app port", registry.ErrInvalid)
		}
		plan.Kind, plan.Port = "port", port
		return plan, ctx.Err()
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return plan, err
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return plan, err
	}
	directory := app.StaticDirectory
	if !filepath.IsAbs(directory) {
		directory = filepath.Join(root, directory)
	}
	directory, err = filepath.EvalSymlinks(directory)
	if err != nil {
		return plan, err
	}
	directory, err = filepath.Abs(directory)
	if err != nil {
		return plan, err
	}
	relative, err := filepath.Rel(root, directory)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return plan, fmt.Errorf("%w: publish a dedicated static build folder inside the app's project", registry.ErrInvalid)
	}
	for _, component := range strings.Split(relative, string(filepath.Separator)) {
		if strings.HasPrefix(component, ".") {
			return plan, fmt.Errorf("%w: publish a dedicated public build folder, not a private project directory", registry.ErrInvalid)
		}
	}
	index, err := os.Stat(filepath.Join(directory, "index.html"))
	if err != nil || !index.Mode().IsRegular() {
		return plan, fmt.Errorf("%w: the static build needs an index.html", registry.ErrInvalid)
	}
	var count int
	var size int64
	err = filepath.WalkDir(directory, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		count++
		if count > 10000 {
			return fmt.Errorf("%w: static build exceeds 10000 entries", registry.ErrInvalid)
		}
		name := strings.ToLower(entry.Name())
		if entry.Type()&os.ModeSymlink != 0 || path != directory && (strings.HasPrefix(name, ".") && name != ".well-known" || name == "node_modules" || name == "credentials.json" || name == "daemon.token" || name == "auth.json" || strings.HasSuffix(name, ".pem") || strings.HasSuffix(name, ".key") || strings.HasSuffix(name, ".sqlite") || strings.HasSuffix(name, ".db")) {
			return fmt.Errorf("%w: remove private files and symbolic links from the static build before publishing", registry.ErrInvalid)
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("%w: static builds can only contain regular files", registry.ErrInvalid)
		}
		size += info.Size()
		if size > 100<<20 {
			return fmt.Errorf("%w: static build exceeds 100 MB", registry.ErrInvalid)
		}
		return nil
	})
	plan.Kind, plan.Directory = "static", directory
	return plan, err
}
