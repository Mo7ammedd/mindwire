package webui_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/api"
	"github.com/oblien/mindwire/packages/daemon/internal/webui"
)

func TestBrowserShellIsPublicButWorkspaceStillRequiresToken(t *testing.T) {
	mux := http.NewServeMux()
	webui.Register(mux)
	private := http.NewServeMux()
	private.HandleFunc("GET /workspace", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{"chats":[]}`)) })
	mux.Handle("/", api.Auth("private-token", private))
	for _, path := range []string{"/ui/", "/ui/handoffs.js", "/ui/handoffs.css"} {
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, httptest.NewRequest("GET", path, nil))
		if response.Code != 200 || response.Header().Get("Cache-Control") != "no-store" || !strings.Contains(response.Header().Get("Content-Security-Policy"), "script-src 'self'") || strings.Contains(response.Body.String(), "private-token") {
			t.Fatalf("unsafe or unavailable static UI at %s: %d", path, response.Code)
		}
	}
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, httptest.NewRequest("GET", "/workspace", nil))
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("workspace leaked without a token: %d", response.Code)
	}
	request := httptest.NewRequest("GET", "/workspace", nil)
	request.Header.Set("Authorization", "Bearer private-token")
	response = httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("authenticated workspace unavailable: %d", response.Code)
	}
}
