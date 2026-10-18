package computer

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

// PeerBridge grants a daemon a bot-only channel. It never grants the phone's
// workspace API, pairing credentials, shell or port-forwarding capabilities.
// The bot service owns key enrollment, scope checks and revocation.
type PeerBridge interface {
	PeerAuthorize(user string, key ssh.PublicKey) (string, bool)
	ServePeerChannel(id string, incoming ssh.NewChannel)
}

// PeerDirectorySource supplies separately enrolled bot peers with read access
// to encrypted address records. These readers are never computer Devices and
// gain no workspace API, shell, pairing or port-forwarding authorization.
// Callers must not hold the peer registry lock while calling back into Server.
type PeerDirectorySource interface {
	PeerDirectoryReaders() []PeerDirectoryReader
}

type PeerDirectoryReader struct {
	ID        string
	PublicKey string
}

// PeerDiscoveryGrant is private recovery material for an enrolled daemon. It
// travels only inside the authenticated peer channel, never public descriptors,
// owner-facing discovery responses, prompts or model-visible tool results.
type PeerDiscoveryGrant struct {
	Version            int    `json:"version"`
	URL                string `json:"url"`
	DirectoryID        string `json:"directoryId"`
	ComputerID         string `json:"computerId"`
	RegistryID         string `json:"registryId"`
	DeviceID           string `json:"deviceId"`
	Sequence           uint64 `json:"sequence"`
	Secret             string `json:"secret"`
	HostKeyFingerprint string `json:"hostKeyFingerprint"`
}

func (s *Server) SetBotPeerBridge(bridge PeerBridge) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.botPeerBridge = bridge
	s.botPeerDiscoveryChangedLocked()
}

// BotPeerDiscoveryChanged refreshes only encrypted directory reader grants.
// The bridge calls this after committing enrollment/revocation and releasing
// its own lock so publisher snapshots cannot invert the two lock orders.
func (s *Server) BotPeerDiscoveryChanged() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.botPeerDiscoveryChangedLocked()
}

func (s *Server) botPeerDiscoveryChangedLocked() {
	if s.closed || s.state.Discovery == nil {
		return
	}
	if _, err := s.prepareDiscoveryLocked(time.Now()); err != nil {
		s.discoveryError = err.Error()
	}
	// The existing publisher owns retries, including a failed local save.
	s.startDiscoveryLocked()
}

// approvedPeerDirectoryReadersLocked validates each reader independently: a malformed
// peer entry cannot stop address recovery for already approved phones.
func (s *Server) approvedPeerDirectoryReadersLocked() []PeerDirectoryReader {
	source, ok := s.botPeerBridge.(PeerDirectorySource)
	if !ok {
		return nil
	}
	readers := []PeerDirectoryReader{}
	seen := map[string]bool{}
	for _, reader := range source.PeerDirectoryReaders() {
		key, _, options, rest, err := ssh.ParseAuthorizedKey([]byte(reader.PublicKey))
		if err != nil || len(options) != 0 || len(rest) != 0 || key.Type() != ssh.KeyAlgoED25519 || reader.ID != keyID(key) || seen[reader.ID] {
			continue
		}
		seen[reader.ID] = true
		readers = append(readers, PeerDirectoryReader{ID: reader.ID, PublicKey: string(ssh.MarshalAuthorizedKey(key))})
	}
	slices.SortFunc(readers, func(a, b PeerDirectoryReader) int { return strings.Compare(a.ID, b.ID) })
	return readers
}

// The directory accepts at most 64 readers. Saved phone recovery retains its
// existing priority; the sorted peer snapshot uses only the remaining slots.
func (s *Server) eligiblePeerDirectoryReadersLocked(readers []PeerDirectoryReader) []PeerDirectoryReader {
	seen := map[string]bool{}
	for _, device := range s.state.Devices {
		if !device.Revoked {
			seen[device.ID] = true
		}
	}
	out := []PeerDirectoryReader{}
	for _, reader := range readers {
		if seen[reader.ID] || len(seen) < 64 {
			out = append(out, reader)
			seen[reader.ID] = true
		}
	}
	return out
}

func (s *Server) peerDirectoryReadersLocked() []PeerDirectoryReader {
	return s.eligiblePeerDirectoryReadersLocked(s.approvedPeerDirectoryReadersLocked())
}

func (s *Server) BotPeerRecovery(publicKey string) (*PeerDiscoveryGrant, error) {
	key, _, options, rest, err := ssh.ParseAuthorizedKey([]byte(publicKey))
	if err != nil || len(options) != 0 || len(rest) != 0 || key.Type() != ssh.KeyAlgoED25519 {
		return nil, errors.New("invalid bot peer recovery key")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.state.Discovery
	if s.closed || s.signer == nil || d == nil || !d.Enabled {
		return nil, nil
	}
	id := keyID(key)
	readers := s.approvedPeerDirectoryReadersLocked()
	allowed := false
	for _, reader := range readers {
		if reader.ID == id {
			allowed = true
			break
		}
	}
	if !allowed {
		return nil, errors.New("bot peer is not authorized for address recovery")
	}
	eligible := false
	for _, reader := range s.eligiblePeerDirectoryReadersLocked(readers) {
		if reader.ID == id {
			eligible = true
			break
		}
	}
	if !eligible {
		return nil, errors.New("directory reader capacity reached for bot peer address recovery")
	}
	prepared, err := s.prepareDiscoveryLocked(time.Now())
	if err != nil {
		return nil, err
	}
	s.startDiscoveryLocked()
	// Enrollment may change between the source snapshots. Issue a secret only
	// when this exact prepared publication actually includes the reader.
	var publication directoryPublication
	if prepared.Pending == nil {
		return nil, errors.New("bot peer address recovery publication is unavailable")
	}
	payload, err := base64.StdEncoding.DecodeString(prepared.Pending.Payload)
	if err != nil || json.Unmarshal(payload, &publication) != nil {
		return nil, errors.New("bot peer address recovery publication is invalid")
	}
	if !slices.ContainsFunc(publication.Readers, func(reader directoryReader) bool { return reader.DeviceID == id }) {
		return nil, errors.New("bot peer address recovery changed or directory reader capacity was reached")
	}
	return &PeerDiscoveryGrant{
		Version: 1, URL: prepared.URL, DirectoryID: keyID(s.signer.PublicKey()),
		ComputerID: s.state.ID, RegistryID: s.registryID, DeviceID: id,
		Sequence: prepared.Sequence, Secret: base64.StdEncoding.EncodeToString(s.directoryKey(prepared.URL, id)),
		HostKeyFingerprint: s.Fingerprint(),
	}, nil
}

// BotPeerIdentity returns the existing pinned computer identity and a detached
// route snapshot. Reading it neither changes saved phone approvals nor opens a
// listener. Route changes remain owned by the normal computer connection flow.
func (s *Server) BotPeerIdentity() (fingerprint string, routes []Route) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.signer == nil {
		return "", nil
	}
	return s.Fingerprint(), append([]Route{}, s.state.Routes...)
}

func (s *Server) peerBridge() PeerBridge {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	return s.botPeerBridge
}
