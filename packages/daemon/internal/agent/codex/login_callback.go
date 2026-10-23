package codex

import (
	"context"
	"crypto/subtle"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func (m *authModule) Callback(_ context.Context, flowID, rawURL string) (agent.AuthState, error) {
	m.mu.Lock()
	flow := m.login
	m.mu.Unlock()
	if flow == nil {
		return agent.AuthState{}, errors.New("no sign-in in progress")
	}
	return flow.Step(map[string]string{agent.AuthFlowIDKey: flowID, agent.AuthCallbackKey: rawURL})
}

// Only the callback issued by this native login can be delivered. The browser
// response uses the existing authenticated daemon transport, so cloud runtimes,
// paired computers, SSH hosts and containers all reach their own loopback.
func bindLoginCallback(flow *agent.AuthFlow, authURL string) (string, error) {
	authorize, err := url.Parse(authURL)
	if err != nil || authorize.Scheme != "https" {
		return "", errors.New("invalid native sign-in URL")
	}
	params, err := url.ParseQuery(authorize.RawQuery)
	if err != nil || len(params["redirect_uri"]) != 1 || len(params["state"]) != 1 || params.Get("state") == "" {
		return "", errors.New("missing native sign-in callback")
	}
	callback, err := url.Parse(params.Get("redirect_uri"))
	if err != nil {
		return "", errors.New("invalid native sign-in callback")
	}
	port, err := strconv.Atoi(callback.Port())
	host := callback.Hostname()
	if err != nil || port < 1024 || port > 65535 || callback.Scheme != "http" || callback.User != nil ||
		callback.Path != "/auth/callback" || callback.RawQuery != "" || callback.Fragment != "" ||
		(host != "localhost" && host != "127.0.0.1" && host != "::1") {
		return "", errors.New("invalid native sign-in callback")
	}
	state := params.Get("state")
	dialHost := host
	if dialHost == "localhost" {
		dialHost = "127.0.0.1"
	}
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true, ResponseHeaderTimeout: 25 * time.Second}
	client := &http.Client{Transport: transport, Timeout: 30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	flow.SetCallback(func(rawURL string) error {
		returned, err := url.Parse(rawURL)
		if err != nil || returned.Scheme != callback.Scheme || returned.Host != callback.Host ||
			returned.EscapedPath() != callback.EscapedPath() || returned.User != nil || returned.Fragment != "" {
			return errors.New("unexpected native sign-in callback")
		}
		values, err := url.ParseQuery(returned.RawQuery)
		if err != nil || len(values["state"]) != 1 || subtle.ConstantTimeCompare([]byte(values.Get("state")), []byte(state)) != 1 ||
			(values.Get("code") == "" && values.Get("error") == "") {
			return errors.New("unexpected native sign-in response")
		}
		// Pin the native loopback target; never use proxy environment variables,
		// a caller-selected host, or a redirect returned by the native listener.
		target := *callback
		target.RawQuery = returned.RawQuery
		target.Host = net.JoinHostPort(dialHost, callback.Port())
		req, err := http.NewRequestWithContext(flow.Context(), http.MethodGet, target.String(), nil)
		if err != nil {
			return errors.New("couldn't create native sign-in callback")
		}
		req.Host = callback.Host
		response, err := client.Do(req)
		if err != nil {
			return errors.New("native sign-in callback unavailable")
		}
		defer response.Body.Close()
		// Do not expose native HTML or Location headers, which can contain OAuth
		// data. Only account/login/completed confirms authentication to clients.
		if response.StatusCode < 200 || response.StatusCode >= 400 {
			return errors.New("native sign-in callback failed")
		}
		return nil
	})
	return callback.String(), nil
}
