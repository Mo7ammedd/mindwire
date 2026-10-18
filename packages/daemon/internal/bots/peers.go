package bots

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/oblien/mindwire/packages/daemon/internal/computer"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"golang.org/x/crypto/ssh"
)

const peerChannel = "mindwire-bots"
const peerActorPrefix = "\x00peer:" // control character is rejected for persisted bot IDs
const peerStateKey = "#mindwire-bots:peers"

type PeerRoute struct {
	Kind string `json:"kind"`
	Host string `json:"host,omitempty"`
	Port int    `json:"port,omitempty"`
	URL  string `json:"url,omitempty"`
}

type Peer struct {
	WorkspaceID        string      `json:"workspaceId"`
	Name               string      `json:"name"`
	PublicKey          string      `json:"publicKey"`
	HostKeyFingerprint string      `json:"hostKeyFingerprint"`
	Routes             []PeerRoute `json:"routes"`
	Enabled            bool        `json:"enabled"`
}

type PeerIdentity struct {
	WorkspaceID        string      `json:"workspaceId"`
	PublicKey          string      `json:"publicKey"`
	HostKeyFingerprint string      `json:"hostKeyFingerprint"`
	Port               int         `json:"port,omitempty"`
	SSHPort            int         `json:"sshPort,omitempty"`
	Routes             []PeerRoute `json:"routes,omitempty"`
}

type peerState struct {
	PrivateKey string                  `json:"privateKey"`
	Port       int                     `json:"port,omitempty"`
	SSHPort    int                     `json:"sshPort,omitempty"`
	Peers      map[string]Peer         `json:"peers"`
	Recovery   map[string]peerRecovery `json:"recovery,omitempty"`
}

type peerManager struct {
	mu               sync.Mutex
	state            peerState
	signer           ssh.Signer
	listener         net.Listener
	sshListener      net.Listener
	server           *http.Server
	nativeIdentity   func() (string, []PeerRoute)
	discoveryGrant   func(string) (*computer.PeerDiscoveryGrant, error)
	discoveryChanged func()
	connections      map[*ssh.ServerConn]string
	closed           bool
	err              error
	listenerError    error
	limit            chan struct{}
}

func (s *Service) initPeers() {
	p := &peerManager{connections: map[*ssh.ServerConn]string{}, limit: make(chan struct{}, 32)}
	s.peers = p
	raw := s.history.Get(peerStateKey)
	if raw != "" {
		p.err = json.Unmarshal([]byte(raw), &p.state)
	}
	if p.err != nil {
		return
	}
	if p.state.Recovery == nil {
		p.state.Recovery = map[string]peerRecovery{}
	}
	if p.state.Peers == nil {
		p.state.Peers = map[string]Peer{}
	}
	if p.state.PrivateKey == "" {
		_, key, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			p.err = err
			return
		}
		p.state.PrivateKey = base64.StdEncoding.EncodeToString(key)
		p.err = s.persistPeersLocked()
		if p.err != nil {
			return
		}
	}
	key, err := base64.StdEncoding.DecodeString(p.state.PrivateKey)
	if err != nil || len(key) != ed25519.PrivateKeySize {
		p.err = errors.New("invalid saved bot peer identity")
		return
	}
	p.signer, p.err = ssh.NewSignerFromKey(ed25519.PrivateKey(key))
	if p.err == nil && p.state.Port > 0 {
		p.listenerError = s.startPeerListenerLocked(p.state.Port)
	}
}

func (s *Service) persistPeersLocked() error {
	data, err := json.Marshal(s.peers.state)
	if err != nil {
		return err
	}
	return s.history.SetMany(map[string]string{peerStateKey: string(data)})
}

// A computer's existing SSH listener can carry the same peer-only channel. The
// callback supplies its pinned host identity/routes; no phone key is reused.
func (s *Service) SetComputerPeerIdentity(identity func() (string, []PeerRoute)) {
	s.peers.mu.Lock()
	defer s.peers.mu.Unlock()
	s.peers.nativeIdentity = identity
}

func (s *Service) PeerIdentity() (PeerIdentity, error) {
	p := s.peers
	p.mu.Lock()
	if p.err != nil {
		p.mu.Unlock()
		return PeerIdentity{}, p.err
	}
	identity := PeerIdentity{WorkspaceID: s.db.Identity(), PublicKey: string(ssh.MarshalAuthorizedKey(p.signer.PublicKey())), HostKeyFingerprint: ssh.FingerprintSHA256(p.signer.PublicKey()), Port: p.state.Port, SSHPort: p.state.SSHPort}
	active, native := p.listener != nil, p.nativeIdentity
	p.mu.Unlock()
	if !active {
		identity.Port = 0
		identity.SSHPort = 0
		if native != nil {
			identity.HostKeyFingerprint, identity.Routes = native()
		}
	}
	return identity, nil
}

func (s *Service) Peers() ([]Peer, error) {
	p := s.peers
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.err != nil {
		return nil, p.err
	}
	out := make([]Peer, 0, len(p.state.Peers))
	for _, peer := range p.state.Peers {
		peer.Routes = append([]PeerRoute{}, peer.Routes...)
		out = append(out, peer)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].WorkspaceID < out[j].WorkspaceID })
	return out, nil
}

func (s *Service) SavePeer(id string, input Peer) (Peer, error) {
	if id == "" || id == s.db.Identity() || len(id) > 512 || strings.IndexFunc(id, func(r rune) bool { return r < 32 || r == 127 }) >= 0 || len(input.Name) > 120 {
		return Peer{}, fmt.Errorf("%w: invalid peer identity", registry.ErrInvalid)
	}
	key, _, options, rest, err := ssh.ParseAuthorizedKey([]byte(input.PublicKey))
	if err != nil || len(options) != 0 || len(rest) != 0 || key.Type() != ssh.KeyAlgoED25519 {
		return Peer{}, fmt.Errorf("%w: an Ed25519 peer public key is required", registry.ErrInvalid)
	}
	if !strings.HasPrefix(input.HostKeyFingerprint, "SHA256:") || len(input.HostKeyFingerprint) > 100 || len(input.Routes) > 8 {
		return Peer{}, fmt.Errorf("%w: invalid peer host identity or routes", registry.ErrInvalid)
	}
	for _, route := range input.Routes {
		if err := validPeerRoute(route); err != nil {
			return Peer{}, err
		}
	}
	input.WorkspaceID = id
	input.PublicKey = string(ssh.MarshalAuthorizedKey(key))
	input.Routes = append([]PeerRoute{}, input.Routes...)
	p := s.peers
	p.mu.Lock()
	changed := false
	defer func() {
		notify := p.discoveryChanged
		p.mu.Unlock()
		if changed && notify != nil {
			notify()
		}
	}()
	if p.err != nil {
		return Peer{}, p.err
	}
	if p.closed {
		return Peer{}, errors.New("bot peer service is closed")
	}
	if _, found := p.state.Peers[id]; !found && len(p.state.Peers) >= 32 {
		return Peer{}, fmt.Errorf("%w: up to 32 linked computers are supported", registry.ErrInvalid)
	}
	old, exists := p.state.Peers[id]
	oldRecovery, hadRecovery := p.state.Recovery[id]
	if old.PublicKey != input.PublicKey || old.HostKeyFingerprint != input.HostKeyFingerprint {
		delete(p.state.Recovery, id)
	}
	p.state.Peers[id] = input
	if err = s.persistPeersLocked(); err != nil {
		if hadRecovery {
			p.state.Recovery[id] = oldRecovery
		}
		if exists {
			p.state.Peers[id] = old
		} else {
			delete(p.state.Peers, id)
		}
		return Peer{}, err
	}
	if !input.Enabled || old.PublicKey != input.PublicKey {
		for conn, peerID := range p.connections {
			if peerID == id {
				_ = conn.Close()
			}
		}
	}
	changed = true
	return input, nil
}

func (s *Service) RemovePeer(id string) error {
	p := s.peers
	p.mu.Lock()
	changed := false
	defer func() {
		notify := p.discoveryChanged
		p.mu.Unlock()
		if changed && notify != nil {
			notify()
		}
	}()
	if p.err != nil {
		return p.err
	}
	old, exists := p.state.Peers[id]
	if !exists {
		return nil
	}
	oldRecovery, hadRecovery := p.state.Recovery[id]
	delete(p.state.Recovery, id)
	delete(p.state.Peers, id)
	if err := s.persistPeersLocked(); err != nil {
		p.state.Peers[id] = old
		if hadRecovery {
			p.state.Recovery[id] = oldRecovery
		}
		return err
	}
	for conn, peerID := range p.connections {
		if peerID == id {
			_ = conn.Close()
		}
	}
	changed = true
	return nil
}

func (s *Service) StartPeerListener(port int) (PeerIdentity, error) {
	p := s.peers
	p.mu.Lock()
	if p.err != nil {
		p.mu.Unlock()
		return PeerIdentity{}, p.err
	}
	if port < 0 || port > 65535 {
		p.mu.Unlock()
		return PeerIdentity{}, fmt.Errorf("%w: invalid peer listener port", registry.ErrInvalid)
	}
	if p.listener != nil {
		if port != 0 && port != p.state.Port {
			p.mu.Unlock()
			return PeerIdentity{}, fmt.Errorf("%w: the peer listener already uses a different port", registry.ErrConflict)
		}
	} else {
		oldPort, oldSSHPort := p.state.Port, p.state.SSHPort
		if err := s.startPeerListenerLocked(port); err != nil {
			p.mu.Unlock()
			return PeerIdentity{}, err
		}
		if err := s.persistPeersLocked(); err != nil {
			_ = p.server.Close()
			_ = p.sshListener.Close()
			p.sshListener = nil
			p.state.SSHPort = oldSSHPort
			p.listener = nil
			p.server = nil
			p.state.Port = oldPort
			p.mu.Unlock()
			return PeerIdentity{}, err
		}
		p.listenerError = nil
	}
	p.mu.Unlock()
	return s.PeerIdentity()
}

func (s *Service) startPeerListenerLocked(port int) error {
	p := s.peers
	if p.closed {
		return errors.New("bot peer service is closed")
	}
	listener, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", port))
	if err != nil {
		return err
	}
	sshListener, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", p.state.SSHPort))
	if err != nil && port == 0 {
		sshListener, err = net.Listen("tcp", "0.0.0.0:0")
	}
	if err != nil {
		_ = listener.Close()
		return err
	}
	p.sshListener = sshListener
	p.state.SSHPort = sshListener.Addr().(*net.TCPAddr).Port
	mux := http.NewServeMux()
	mux.HandleFunc("GET /ssh", s.peerWebSocket)
	p.listener = listener
	p.state.Port = listener.Addr().(*net.TCPAddr).Port
	p.server = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}
	server := p.server
	go func() { _ = server.Serve(listener) }()
	go func() {
		for {
			raw, err := sshListener.Accept()
			if err != nil {
				return
			}
			go s.handlePeerConn(raw)
		}
	}()
	return nil
}

func (s *Service) PeerAuthorize(user string, key ssh.PublicKey) (string, bool) {
	id, ok := strings.CutPrefix(user, "bot-peer:")
	if !ok {
		return "", false
	}
	p := s.peers
	p.mu.Lock()
	defer p.mu.Unlock()
	peer, exists := p.state.Peers[id]
	if p.err != nil || p.closed || !exists || !peer.Enabled {
		return "", false
	}
	expected, _, _, _, err := ssh.ParseAuthorizedKey([]byte(peer.PublicKey))
	return id, err == nil && subtle.ConstantTimeCompare(expected.Marshal(), key.Marshal()) == 1
}

func (s *Service) peerActor(actor registry.Bot) (registry.Bot, bool, error) {
	id, ok := strings.CutPrefix(actor.ID, peerActorPrefix)
	if !ok {
		return registry.Bot{}, false, nil
	}
	p := s.peers
	p.mu.Lock()
	defer p.mu.Unlock()
	peer, exists := p.state.Peers[id]
	if !exists || !peer.Enabled || p.closed {
		return registry.Bot{}, true, errors.New("this computer link was revoked")
	}
	return registry.Bot{Record: registry.Record{ID: actor.ID, WorkspaceID: s.db.Identity()}, Name: "Mindwire", IsMaster: true}, true, nil
}

func (s *Service) peerWebSocket(w http.ResponseWriter, r *http.Request) {
	// No owner API or shell is exposed here. TLS is an outer carrier; pinned SSH
	// and an individually authorized peer public key protect every operation.
	if r.Header.Get("Origin") != "" {
		http.Error(w, "browser origins are not allowed", http.StatusForbidden)
		return
	}
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return
	}
	defer ws.CloseNow()
	ws.SetReadLimit(1 << 20)
	raw := websocket.NetConn(r.Context(), ws, websocket.MessageBinary)
	s.handlePeerConn(raw)
}

func (s *Service) handlePeerConn(raw net.Conn) {
	defer raw.Close()
	p := s.peers
	select {
	case p.limit <- struct{}{}:
		defer func() { <-p.limit }()
	default:
		return
	}
	p.mu.Lock()
	signer := p.signer
	p.mu.Unlock()
	config := &ssh.ServerConfig{MaxAuthTries: 3, PublicKeyCallback: func(meta ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
		id, ok := s.PeerAuthorize(meta.User(), key)
		if !ok {
			return nil, errors.New("peer denied")
		}
		return &ssh.Permissions{Extensions: map[string]string{"bot-peer": id, "peer-key": string(ssh.MarshalAuthorizedKey(key))}}, nil
	}}
	config.AddHostKey(signer)
	_ = raw.SetDeadline(time.Now().Add(15 * time.Second))
	conn, channels, requests, err := ssh.NewServerConn(raw, config)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = raw.SetDeadline(time.Time{})
	id := conn.Permissions.Extensions["bot-peer"]
	p.mu.Lock()
	p.connections[conn] = id
	p.mu.Unlock()
	defer func() { p.mu.Lock(); delete(p.connections, conn); p.mu.Unlock() }()
	go ssh.DiscardRequests(requests)
	for channel := range channels {
		key, _, _, rest, err := ssh.ParseAuthorizedKey([]byte(conn.Permissions.Extensions["peer-key"]))
		if err != nil || len(rest) != 0 {
			_ = channel.Reject(ssh.Prohibited, "peer denied")
			continue
		}
		current, allowed := s.PeerAuthorize(conn.User(), key)
		if !allowed || current != id {
			_ = channel.Reject(ssh.Prohibited, "peer denied")
			continue
		}
		s.ServePeerChannel(id, channel)
	}
}

type peerRequest struct {
	WorkspaceID string          `json:"workspaceId"`
	Tool        string          `json:"tool"`
	Arguments   json.RawMessage `json:"arguments"`
}
type peerResponse struct {
	Recovery    *computer.PeerDiscoveryGrant `json:"recovery,omitempty"`
	WorkspaceID string                       `json:"workspaceId"`
	Result      json.RawMessage              `json:"result,omitempty"`
	Error       string                       `json:"error,omitempty"`
}

// ServePeerChannel is also plugged into the existing computer SSH server. It
// deliberately accepts no direct-tcpip, shell, owner API or approval-response channel.
func (s *Service) ServePeerChannel(id string, incoming ssh.NewChannel) {
	if incoming.ChannelType() != peerChannel {
		_ = incoming.Reject(ssh.UnknownChannelType, "use the bot management channel")
		return
	}
	channel, requests, err := incoming.Accept()
	if err != nil {
		return
	}
	defer channel.Close()
	go ssh.DiscardRequests(requests)
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { _ = channel.Close() })
	defer stop()
	var input peerRequest
	if err = json.NewDecoder(io.LimitReader(channel, 1<<20)).Decode(&input); err != nil {
		_ = json.NewEncoder(channel).Encode(peerResponse{WorkspaceID: s.db.Identity(), Error: "invalid bot request"})
		return
	}
	if input.WorkspaceID != s.db.Identity() {
		_ = json.NewEncoder(channel).Encode(peerResponse{WorkspaceID: s.db.Identity(), Error: "linked computer workspace identity changed; reconnect it in Mindwire"})
		return
	}
	actor := registry.Bot{Record: registry.Record{ID: peerActorPrefix + id, WorkspaceID: s.db.Identity()}, IsMaster: true}
	if _, _, err = s.peerActor(actor); err != nil {
		_ = json.NewEncoder(channel).Encode(peerResponse{WorkspaceID: s.db.Identity(), Error: err.Error()})
		return
	}
	// SSH operations share owner HTTP's idle-update admission. Without this,
	// remote metadata writes could enter after a replacement lease was acquired.
	if admission, ok := s.runtime.(interface{ BeginServiceOperation() (func(), error) }); ok {
		done, err := admission.BeginServiceOperation()
		if err != nil {
			_ = json.NewEncoder(channel).Encode(peerResponse{WorkspaceID: s.db.Identity(), Error: err.Error()})
			return
		}
		defer done()
	}
	// The exact local tools enforce schemas, revisions and task admission. A peer
	// actor cannot federate again, making every trust edge strictly one hop.
	server := s.server(actor)
	clientTransport, serverTransport := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(ctx, serverTransport, nil)
	if err != nil {
		return
	}
	defer serverSession.Close()
	client := mcp.NewClient(&mcp.Implementation{Name: "mindwire-peer", Version: "1"}, nil)
	session, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		return
	}
	defer session.Close()
	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: input.Tool, Arguments: input.Arguments})
	response := peerResponse{WorkspaceID: s.db.Identity(), Recovery: s.recoveryForPeer(id)}
	if err != nil {
		response.Error = err.Error()
	} else if result.IsError {
		response.Error = "remote bot operation failed"
		for _, content := range result.Content {
			if text, ok := content.(*mcp.TextContent); ok {
				response.Error = text.Text
				break
			}
		}
	} else {
		response.Result, _ = json.Marshal(result.StructuredContent)
	}
	_ = json.NewEncoder(channel).Encode(response)
}

func (s *Service) callPeer(ctx context.Context, peer Peer, tool string, args any) (any, error) {
	return s.callPeerAttempt(ctx, peer, tool, args, true)
}
func (s *Service) callPeerAttempt(ctx context.Context, peer Peer, tool string, args any, recoverAddress bool) (any, error) {
	p := s.peers
	p.mu.Lock()
	signer := p.signer
	p.mu.Unlock()
	if !peer.Enabled {
		return nil, errors.New("this computer link is disabled")
	}
	rawArgs, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	var argsMap map[string]json.RawMessage
	if json.Unmarshal(rawArgs, &argsMap) != nil {
		return nil, errors.New("invalid bot arguments")
	}
	delete(argsMap, "workspaceId")
	rawArgs, _ = json.Marshal(argsMap)
	if len(peer.Routes) == 0 {
		if recoverAddress {
			if recovered, err := s.recoverPeer(ctx, peer); err == nil {
				return s.callPeerAttempt(ctx, recovered, tool, args, false)
			}
		}
		return nil, errors.New("this computer has no reachable peer route")
	}
	ctx, cancel := context.WithTimeout(ctx, 40*time.Second)
	defer cancel()
	var client *ssh.Client
	var last error
	routeParent := ctx
	// Reserve time for directory recovery instead of letting several dead saved
	// addresses consume the caller's entire discovery/check deadline.
	p.mu.Lock()
	_, hasRecovery := p.state.Recovery[peer.WorkspaceID]
	p.mu.Unlock()
	if recoverAddress && hasRecovery {
		var cancelRoutes context.CancelFunc
		routeParent, cancelRoutes = context.WithTimeout(ctx, 3*time.Second)
		defer cancelRoutes()
	}
	for _, route := range peer.Routes {
		if routeParent.Err() != nil {
			last = routeParent.Err()
			break
		}
		var raw net.Conn
		routeCtx, routeCancel := context.WithTimeout(routeParent, 8*time.Second)
		if route.Kind == "ssh" {
			raw, err = (&net.Dialer{}).DialContext(routeCtx, "tcp", net.JoinHostPort(route.Host, fmt.Sprint(route.Port)))
		} else {
			var ws *websocket.Conn
			ws, _, err = websocket.Dial(routeCtx, route.URL, nil)
			if err == nil {
				ws.SetReadLimit(1 << 20)
				raw = websocket.NetConn(ctx, ws, websocket.MessageBinary)
			}
		}
		routeCancel()
		if err != nil {
			last = err
			continue
		}
		config := &ssh.ClientConfig{User: "bot-peer:" + s.db.Identity(), Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)}, HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			if subtle.ConstantTimeCompare([]byte(ssh.FingerprintSHA256(key)), []byte(peer.HostKeyFingerprint)) != 1 {
				return errors.New("linked computer identity changed")
			}
			return nil
		}}
		deadline := time.Now().Add(8 * time.Second)
		if overall, ok := routeParent.Deadline(); ok && overall.Before(deadline) {
			deadline = overall
		}
		_ = raw.SetDeadline(deadline)
		stopHandshake := context.AfterFunc(routeParent, func() { _ = raw.Close() })
		conn, channels, requests, e := ssh.NewClientConn(raw, "mindwire-peer", config)
		stopHandshake()
		if e != nil {
			_ = raw.Close()
			last = e
			continue
		}
		_ = raw.SetDeadline(time.Time{})
		client = ssh.NewClient(conn, channels, requests)
		break
	}
	if client == nil {
		if recoverAddress && ctx.Err() == nil {
			if recovered, err := s.recoverPeer(ctx, peer); err == nil {
				return s.callPeerAttempt(ctx, recovered, tool, args, false)
			}
		}
		return nil, fmt.Errorf("cannot reach %s: %w", peer.Name, last)
	}
	if !recoverAddress {
		s.rememberPeerRoutes(peer)
	}
	defer client.Close()
	stop := context.AfterFunc(ctx, func() { _ = client.Close() })
	defer stop()
	channel, requests, err := client.OpenChannel(peerChannel, nil)
	if err != nil {
		return nil, err
	}
	defer channel.Close()
	go ssh.DiscardRequests(requests)
	if err = json.NewEncoder(channel).Encode(peerRequest{WorkspaceID: peer.WorkspaceID, Tool: tool, Arguments: rawArgs}); err != nil {
		return nil, err
	}
	var response peerResponse
	if err = json.NewDecoder(io.LimitReader(channel, 1<<20)).Decode(&response); err != nil {
		return nil, err
	}
	if response.WorkspaceID != peer.WorkspaceID {
		return nil, errors.New("linked computer workspace identity changed; reconnect it in Mindwire")
	}
	if response.Error != "" {
		return nil, errors.New(response.Error)
	}
	// Rejections before handler execution (for example an idle-update lease)
	// do not carry discovery state and must not withdraw a still-valid grant.
	s.learnRecovery(peer, response.Recovery)
	var result any
	if err = json.Unmarshal(response.Result, &result); err != nil {
		return nil, err
	}
	return result, nil
}

func (s *Service) Close() {
	if s.peers == nil {
		return
	}
	p := s.peers
	p.mu.Lock()
	defer p.mu.Unlock()
	p.closed = true
	if p.server != nil {
		_ = p.server.Close()
	}
	if p.sshListener != nil {
		_ = p.sshListener.Close()
	}
	for conn := range p.connections {
		_ = conn.Close()
	}
}

// routeTool routes an explicit workspace or aggregates discovery. Remote peers
// only execute locally; they cannot inherit this daemon's other trust grants.
func (s *Service) routeTool(ctx context.Context, actor registry.Bot, name string, input any) (any, bool, error) {
	raw, err := json.Marshal(input)
	if err != nil {
		return nil, true, err
	}
	var args map[string]any
	_ = json.Unmarshal(raw, &args)
	workspace, _ := args["workspaceId"].(string)
	if strings.HasPrefix(actor.ID, peerActorPrefix) {
		if workspace != "" && workspace != s.db.Identity() {
			return nil, true, errors.New("linked computers cannot forward requests to other peers")
		}
		return nil, false, nil
	}
	if !actor.IsMaster {
		if workspace != "" && workspace != s.db.Identity() {
			return nil, true, errors.New("only Mindwire can access linked computers")
		}
		return nil, false, nil
	}
	if workspace == "" && (name == "bots_list" || name == "bots_agents") {
		if _, err := s.authorize(actor, actor.ID, true); err != nil {
			return nil, true, err
		}
		out, err := s.discoverPeers(ctx, name, args)
		return out, true, err
	}
	if workspace == "" || workspace == s.db.Identity() {
		return nil, false, nil
	}
	if _, err := s.authorize(actor, actor.ID, true); err != nil {
		return nil, true, err
	}
	peers, err := s.Peers()
	if err != nil {
		return nil, true, err
	}
	for _, peer := range peers {
		if peer.WorkspaceID == workspace {
			// Preserve per-master retry namespaces across the peer edge. The
			// destination authenticates the source daemon, not its UI profile.
			if id, ok := args["requestId"].(string); ok && id != "" {
				if !validRequest(id) {
					return nil, true, fmt.Errorf("%w: invalid requestId", registry.ErrInvalid)
				}
				args["requestId"] = "peer-" + registry.SyncKey(actor.ID, id)[:48]
			}
			out, err := s.callPeer(ctx, peer, name, args)
			if result, ok := out.(map[string]any); ok {
				result["workspaceId"] = workspace
				if receipt, ok := result["mindwireBot"].(map[string]any); ok {
					receipt["workspaceId"] = workspace
				}
			}
			return out, true, err
		}
	}
	return nil, true, errors.New("this computer is not linked; connect it in Mindwire first")
}

func (s *Service) discoverPeers(ctx context.Context, name string, args map[string]any) (map[string]any, error) {
	out := map[string]any{}
	if name == "bots_list" {
		archived, _ := args["includeArchived"].(bool)
		saved, err := s.db.Bots("", archived)
		if err != nil {
			return nil, err
		}
		entries := []any{}
		for _, bot := range saved {
			entries = append(entries, map[string]any{"id": bot.ID, "workspaceId": bot.WorkspaceID, "agentId": bot.AgentID, "projectId": bot.ProjectID, "name": bot.Name, "icon": bot.Icon, "purpose": bot.Purpose, "revision": bot.Revision, "archived": bot.Archived, "isMaster": bot.IsMaster})
		}
		out["bots"] = entries
	} else {
		agents, projects, err := s.Agents(registry.Bot{})
		if err != nil {
			return nil, err
		}
		aa := []any{}
		for _, a := range agents {
			aa = append(aa, a)
		}
		pp := []any{}
		for _, p := range projects {
			pp = append(pp, p)
		}
		out["agents"] = aa
		out["projects"] = pp
	}
	peers, err := s.Peers()
	if err != nil {
		return nil, err
	}
	type result struct {
		peer  Peer
		value any
		err   error
	}
	results := make(chan result, len(peers))
	limit := make(chan struct{}, 4)
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	var group sync.WaitGroup
	for _, peer := range peers {
		if !peer.Enabled {
			continue
		}
		group.Add(1)
		go func(peer Peer) {
			defer group.Done()
			select {
			case limit <- struct{}{}:
				defer func() { <-limit }()
			case <-ctx.Done():
				results <- result{peer: peer, err: ctx.Err()}
				return
			}
			value, err := s.callPeer(ctx, peer, name, args)
			results <- result{peer, value, err}
		}(peer)
	}
	group.Wait()
	close(results)
	statuses := []map[string]any{}
	for result := range results {
		status := map[string]any{"workspaceId": result.peer.WorkspaceID, "name": result.peer.Name, "connected": result.err == nil}
		if result.err != nil {
			status["error"] = result.err.Error()
		} else if value, ok := result.value.(map[string]any); ok {
			for _, key := range []string{"bots", "agents", "projects"} {
				if rows, ok := value[key].([]any); ok {
					// Stamp the authenticated destination, rather than trusting identifiers in
					// remote content. Model routing is explicit even when display names clash.
					for _, row := range rows {
						if item, ok := row.(map[string]any); ok {
							item["workspaceId"] = result.peer.WorkspaceID
						}
					}
					current, _ := out[key].([]any)
					out[key] = append(current, rows...)
				}
			}
		}
		statuses = append(statuses, status)
	}
	sort.Slice(statuses, func(i, j int) bool { return statuses[i]["workspaceId"].(string) < statuses[j]["workspaceId"].(string) })
	out["computers"] = statuses
	out["workspaceId"] = s.db.Identity()
	return out, nil
}

func validPeerRoute(route PeerRoute) error {
	switch route.Kind {
	case "ssh":
		if route.Host == "" || strings.ContainsAny(route.Host, "/\x00\r\n") || route.Port < 1 || route.Port > 65535 {
			return fmt.Errorf("%w: invalid SSH peer route", registry.ErrInvalid)
		}
	case "websocket":
		u, e := url.Parse(route.URL)
		if e != nil || u.Scheme != "wss" || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
			return fmt.Errorf("%w: peer WebSocket routes must use wss", registry.ErrInvalid)
		}
	default:
		return fmt.Errorf("%w: unknown peer route", registry.ErrInvalid)
	}
	return nil
}

type PeerCheck struct {
	WorkspaceID     string `json:"workspaceId"`
	Reachable       bool   `json:"reachable"`
	Error           string `json:"error,omitempty"`
	AddressRecovery bool   `json:"addressRecovery,omitempty"`
}

func (s *Service) CheckPeer(ctx context.Context, id string) (PeerCheck, error) {
	peers, err := s.Peers()
	if err != nil {
		return PeerCheck{}, err
	}
	for _, peer := range peers {
		if peer.WorkspaceID == id {
			ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
			defer cancel()
			_, err := s.callPeer(ctx, peer, "bots_agents", map[string]any{})
			result := PeerCheck{WorkspaceID: id, Reachable: err == nil}
			if err != nil {
				result.Error = err.Error()
			}
			s.peers.mu.Lock()
			_, result.AddressRecovery = s.peers.state.Recovery[id]
			s.peers.mu.Unlock()
			return result, nil
		}
	}
	return PeerCheck{}, registry.ErrNotFound
}
