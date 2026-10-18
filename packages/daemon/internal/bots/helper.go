package bots

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type helperAuthorization struct{ token string }

func (a helperAuthorization) RoundTrip(r *http.Request) (*http.Response, error) {
	copy := r.Clone(r.Context())
	copy.Header.Set("Authorization", "Bearer "+a.token)
	return http.DefaultTransport.RoundTrip(copy)
}

// ToolHelper gives command-based harnesses the same scoped tools, without the
// daemon's owner credential or persistent changes to native MCP configuration.
func ToolHelper(ctx context.Context, args []string, out io.Writer) error {
	endpoint, err := url.Parse(os.Getenv("MINDWIRE_BOT_TOOL_URL"))
	token := os.Getenv(tokenEnv)
	if err != nil || endpoint.Scheme != "http" || endpoint.Hostname() != "127.0.0.1" || endpoint.Path != "/mcp" || endpoint.User != nil || endpoint.RawQuery != "" || token == "" {
		return errors.New("bot tools are available only inside an active Mindwire bot run")
	}
	if len(args) < 1 || len(args) > 2 {
		return errors.New("usage: --bot-tool list | TOOL_NAME 'JSON_ARGUMENTS'")
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "mindwire-bot-helper", Version: "1"}, nil)
	connection, err := client.Connect(ctx, &mcp.StreamableClientTransport{Endpoint: endpoint.String(), HTTPClient: &http.Client{Transport: helperAuthorization{token}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, DisableStandaloneSSE: true, MaxRetries: -1}, nil)
	if err != nil {
		return errors.New("could not reach this run's bot tools; the run may have ended")
	}
	defer connection.Close()
	if args[0] == "list" {
		tools, err := connection.ListTools(ctx, nil)
		if err != nil {
			return err
		}
		return json.NewEncoder(out).Encode(tools)
	}
	arguments := map[string]any{}
	if len(args) == 2 {
		if len(args[1]) > 1<<20 {
			return errors.New("bot arguments are too large")
		}
		if json.Unmarshal([]byte(args[1]), &arguments) != nil {
			return errors.New("bot arguments must be a JSON object")
		}
	}
	result, err := connection.CallTool(ctx, &mcp.CallToolParams{Name: args[0], Arguments: arguments})
	if err != nil {
		return err
	}
	if err = json.NewEncoder(out).Encode(result); err != nil {
		return err
	}
	if result.IsError {
		return fmt.Errorf("bot tool %s did not complete; see its structured error", args[0])
	}
	return nil
}
