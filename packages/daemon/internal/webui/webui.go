// Package webui serves the daemon's small browser client. Only these static
// assets are public; conversation data and mutations use the authenticated API.
package webui

import (
	"embed"
	"net/http"
)

//go:embed index.html handoffs.css handoffs.js
var assets embed.FS

func Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /ui", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/ui/", http.StatusFound)
	})
	for pattern, name := range map[string]string{
		"/ui/{$}": "index.html", "/ui/handoffs.css": "handoffs.css", "/ui/handoffs.js": "handoffs.js",
	} {
		mux.HandleFunc("GET "+pattern, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("X-Content-Type-Options", "nosniff")
			w.Header().Set("Referrer-Policy", "no-referrer")
			w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
			switch name {
			case "index.html":
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
			case "handoffs.css":
				w.Header().Set("Content-Type", "text/css; charset=utf-8")
			case "handoffs.js":
				w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
			}
			data, err := assets.ReadFile(name)
			if err != nil {
				http.Error(w, "asset unavailable", http.StatusInternalServerError)
				return
			}
			_, _ = w.Write(data)
		})
	}
}
