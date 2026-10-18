package bots

// Reuses the existing computer address directory. Recovery grants can only read
// signed, per-peer encrypted addresses; they cannot authorize SSH or owner APIs.
import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/computer"
	"golang.org/x/crypto/ssh"
)

type peerRecovery struct {
	computer.PeerDiscoveryGrant
	Digest string `json:"digest,omitempty"`
}

func (s *Service) SetPeerDiscovery(grant func(string) (*computer.PeerDiscoveryGrant, error), changed func()) {
	p := s.peers
	p.mu.Lock()
	p.discoveryGrant = grant
	p.discoveryChanged = changed
	p.mu.Unlock()
}

// PeerDirectoryReaders exposes public reader identities only. It does not add
// peers to the phone device registry or grant them the workspace API.
func (s *Service) PeerDirectoryReaders() []computer.PeerDirectoryReader {
	p := s.peers
	p.mu.Lock()
	defer p.mu.Unlock()
	out := []computer.PeerDirectoryReader{}
	if p.err != nil || p.closed {
		return out
	}
	for _, peer := range p.state.Peers {
		if peer.Enabled {
			key, _, _, _, err := ssh.ParseAuthorizedKey([]byte(peer.PublicKey))
			if err != nil {
				continue
			}
			digest := sha256.Sum256(key.Marshal())
			out = append(out, computer.PeerDirectoryReader{ID: base64.RawURLEncoding.EncodeToString(digest[:]), PublicKey: peer.PublicKey})
		}
	}
	return out
}

func (s *Service) recoveryForPeer(id string) *computer.PeerDiscoveryGrant {
	p := s.peers
	p.mu.Lock()
	peer, ok := p.state.Peers[id]
	grant := p.discoveryGrant
	p.mu.Unlock()
	if !ok || !peer.Enabled || grant == nil {
		return nil
	}
	value, err := grant(peer.PublicKey)
	if err != nil {
		return nil
	}
	return value
}

func validRecoveryURL(value string) bool {
	u, err := url.Parse(value)
	return err == nil && len(value) <= 2048 && u.Hostname() != "" && u.User == nil && u.RawQuery == "" && u.Fragment == "" && !strings.HasSuffix(value, "/") && !strings.ContainsAny(value, "\r\n\x00") &&
		(u.Scheme == "https" || u.Scheme == "http" && (u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1"))
}

func (s *Service) learnRecovery(peer Peer, grant *computer.PeerDiscoveryGrant) {
	p := s.peers
	p.mu.Lock()
	defer p.mu.Unlock()
	current, ok := p.state.Peers[peer.WorkspaceID]
	if !ok || !current.Enabled || current.PublicKey != peer.PublicKey || current.HostKeyFingerprint != peer.HostKeyFingerprint {
		return
	}
	if grant == nil {
		// An authenticated response without a grant withdraws prior recovery
		// availability, for example after discovery is disabled or its reader
		// capacity is reached. Never keep advertising a stale reader grant.
		if old, exists := p.state.Recovery[peer.WorkspaceID]; exists {
			delete(p.state.Recovery, peer.WorkspaceID)
			if err := s.persistPeersLocked(); err != nil {
				p.state.Recovery[peer.WorkspaceID] = old
			}
		}
		return
	}
	ownHash := sha256.Sum256(p.signer.PublicKey().Marshal())
	hostHash, err := base64.RawStdEncoding.DecodeString(strings.TrimPrefix(peer.HostKeyFingerprint, "SHA256:"))
	secret, secretErr := base64.StdEncoding.DecodeString(grant.Secret)
	if err != nil || secretErr != nil || len(secret) != 32 || grant.Version != 1 || !validRecoveryURL(grant.URL) || grant.RegistryID != peer.WorkspaceID ||
		grant.HostKeyFingerprint != peer.HostKeyFingerprint || grant.DirectoryID != base64.RawURLEncoding.EncodeToString(hostHash) ||
		grant.DeviceID != base64.RawURLEncoding.EncodeToString(ownHash[:]) || grant.ComputerID == "" || grant.Sequence == 0 || grant.Sequence > 9007199254740991 {
		return
	}
	old, exists := p.state.Recovery[peer.WorkspaceID]
	next := peerRecovery{PeerDiscoveryGrant: *grant}
	if exists && old.URL == grant.URL && old.DirectoryID == grant.DirectoryID && old.DeviceID == grant.DeviceID && old.Secret == grant.Secret {
		if old.Sequence >= next.Sequence {
			next.Sequence = old.Sequence
			next.Digest = old.Digest
		}
	}
	if exists && old == next {
		return
	}
	p.state.Recovery[peer.WorkspaceID] = next
	if err := s.persistPeersLocked(); err != nil {
		if exists {
			p.state.Recovery[peer.WorkspaceID] = old
		} else {
			delete(p.state.Recovery, peer.WorkspaceID)
		}
	}
}

func (s *Service) recoverPeer(ctx context.Context, peer Peer) (Peer, error) {
	p := s.peers
	p.mu.Lock()
	credential, exists := p.state.Recovery[peer.WorkspaceID]
	signer := p.signer
	p.mu.Unlock()
	if !exists || !peer.Enabled || credential.RegistryID != peer.WorkspaceID || credential.HostKeyFingerprint != peer.HostKeyFingerprint || !validRecoveryURL(credential.URL) {
		return Peer{}, errors.New("no trusted address recovery grant for this computer")
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return Peer{}, err
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	timestamp := time.Now().Unix()
	message := fmt.Sprintf("mindwire-directory-lookup-v1\n%s\n%s\n%s\n%d\n%s", credential.URL, credential.DirectoryID, credential.DeviceID, timestamp, nonce)
	signature, err := signer.Sign(rand.Reader, []byte(message))
	if err != nil {
		return Peer{}, err
	}
	body, _ := json.Marshal(map[string]any{"deviceId": credential.DeviceID, "timestamp": timestamp, "nonce": nonce, "signature": base64.StdEncoding.EncodeToString(signature.Blob)})
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, credential.URL+"/records/"+credential.DirectoryID+"/lookup", bytes.NewReader(body))
	if err != nil {
		return Peer{}, err
	}
	request.Header.Set("Content-Type", "application/json")
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		return Peer{}, errors.New("encrypted address recovery is unavailable")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return Peer{}, fmt.Errorf("encrypted address recovery is unavailable (HTTP %d)", response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, 128*1024+1))
	if err != nil || len(raw) > 128*1024 {
		return Peer{}, errors.New("invalid address record")
	}
	var envelope struct {
		PublicKey string `json:"publicKey"`
		Payload   string `json:"payload"`
		Signature string `json:"signature"`
	}
	if json.Unmarshal(raw, &envelope) != nil {
		return Peer{}, errors.New("invalid address envelope")
	}
	public, err := base64.StdEncoding.DecodeString(envelope.PublicKey)
	sig, sigErr := base64.StdEncoding.DecodeString(envelope.Signature)
	payload, payloadErr := base64.StdEncoding.DecodeString(envelope.Payload)
	if err != nil || sigErr != nil || payloadErr != nil || len(public) != 32 || len(sig) != 64 || len(payload) > 65536 {
		return Peer{}, errors.New("invalid address signature")
	}
	host, err := ssh.NewPublicKey(ed25519.PublicKey(public))
	if err != nil || ssh.FingerprintSHA256(host) != peer.HostKeyFingerprint || !ed25519.Verify(ed25519.PublicKey(public), []byte("mindwire-directory-record-v1\n"+envelope.Payload), sig) {
		return Peer{}, errors.New("address signature does not match the linked computer")
	}
	var record struct {
		Version     int    `json:"version"`
		Audience    string `json:"audience"`
		DirectoryID string `json:"directoryId"`
		ComputerID  string `json:"computerId"`
		RegistryID  string `json:"registryId"`
		DeviceID    string `json:"deviceId"`
		Sequence    uint64 `json:"sequence"`
		IssuedAt    int64  `json:"issuedAt"`
		ExpiresAt   int64  `json:"expiresAt"`
		Ciphertext  string `json:"ciphertext"`
	}
	if json.Unmarshal(payload, &record) != nil {
		return Peer{}, errors.New("invalid address payload")
	}
	digestBytes := sha256.Sum256(payload)
	digest := base64.StdEncoding.EncodeToString(digestBytes[:])
	now := time.Now().Unix()
	if record.Version != 1 || record.Audience != credential.URL || record.DirectoryID != credential.DirectoryID || record.ComputerID != credential.ComputerID || record.RegistryID != peer.WorkspaceID || record.DeviceID != credential.DeviceID || record.Sequence == 0 || record.Sequence > 9007199254740991 || record.Sequence < credential.Sequence || (record.Sequence == credential.Sequence && credential.Digest != "" && credential.Digest != digest) || record.IssuedAt < 0 || record.IssuedAt > now+120 || record.ExpiresAt <= now || record.ExpiresAt <= record.IssuedAt || record.ExpiresAt-record.IssuedAt > 86400 {
		return Peer{}, errors.New("address record is expired, rolled back or belongs to another computer")
	}
	secret, err := base64.StdEncoding.DecodeString(credential.Secret)
	if err != nil || len(secret) != 32 {
		return Peer{}, errors.New("invalid recovery grant")
	}
	block, err := aes.NewCipher(secret)
	if err != nil {
		return Peer{}, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return Peer{}, err
	}
	encrypted, err := base64.StdEncoding.DecodeString(record.Ciphertext)
	if err != nil || len(encrypted) < gcm.NonceSize()+gcm.Overhead() || len(encrypted) > 32768+28 {
		return Peer{}, errors.New("invalid encrypted address")
	}
	aad := fmt.Sprintf("mindwire-directory-address-v1\n%s\n%s\n%s\n%d", record.Audience, record.DirectoryID, record.DeviceID, record.Sequence)
	plaintext, err := gcm.Open(nil, encrypted[:gcm.NonceSize()], encrypted[gcm.NonceSize():], []byte(aad))
	if err != nil {
		return Peer{}, errors.New("address record could not be decrypted")
	}
	var addresses struct {
		Routes []PeerRoute `json:"routes"`
	}
	if json.Unmarshal(plaintext, &addresses) != nil || len(addresses.Routes) > 12 {
		return Peer{}, errors.New("invalid recovered routes")
	}
	for _, route := range addresses.Routes {
		if err := validPeerRoute(route); err != nil {
			return Peer{}, err
		}
	}
	// Persist anti-rollback before attempting a connection. Only a subsequent
	// correctly pinned SSH handshake commits these public routes to the peer.
	p.mu.Lock()
	defer p.mu.Unlock()
	current, ok := p.state.Peers[peer.WorkspaceID]
	latest, has := p.state.Recovery[peer.WorkspaceID]
	if !ok || !current.Enabled || current.PublicKey != peer.PublicKey || current.HostKeyFingerprint != peer.HostKeyFingerprint || !has || latest.URL != credential.URL || latest.Secret != credential.Secret || record.Sequence < latest.Sequence || (record.Sequence == latest.Sequence && latest.Digest != "" && latest.Digest != digest) {
		return Peer{}, errors.New("computer recovery changed while resolving")
	}
	next := latest
	next.Sequence = record.Sequence
	next.Digest = digest
	if next != latest {
		p.state.Recovery[peer.WorkspaceID] = next
		if err := s.persistPeersLocked(); err != nil {
			p.state.Recovery[peer.WorkspaceID] = latest
			return Peer{}, err
		}
	}
	peer.Routes = addresses.Routes
	return peer, nil
}

func (s *Service) rememberPeerRoutes(peer Peer) {
	p := s.peers
	p.mu.Lock()
	defer p.mu.Unlock()
	old, ok := p.state.Peers[peer.WorkspaceID]
	if !ok || !old.Enabled || old.PublicKey != peer.PublicKey || old.HostKeyFingerprint != peer.HostKeyFingerprint {
		return
	}
	a, _ := json.Marshal(old.Routes)
	b, _ := json.Marshal(peer.Routes)
	if bytes.Equal(a, b) {
		return
	}
	next := old
	next.Routes = append([]PeerRoute{}, peer.Routes...)
	p.state.Peers[peer.WorkspaceID] = next
	if err := s.persistPeersLocked(); err != nil {
		p.state.Peers[peer.WorkspaceID] = old
	}
}
