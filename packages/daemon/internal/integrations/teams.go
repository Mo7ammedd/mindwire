package integrations

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
)

type teamKey struct {
	Key          *rsa.PublicKey
	Endorsements []string
}
type accessToken struct {
	Value string
	Until time.Time
}

func (s *Service) verifyTeams(ctx context.Context, c savedConnection, authorization string, body []byte) error {
	if !strings.HasPrefix(authorization, "Bearer ") {
		return errForbidden
	}
	parts := strings.Split(strings.TrimPrefix(authorization, "Bearer "), ".")
	if len(parts) != 3 {
		return errForbidden
	}
	header, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return errForbidden
	}
	var h struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if json.Unmarshal(header, &h) != nil || h.Alg != "RS256" || h.Kid == "" {
		return errForbidden
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return errForbidden
	}
	var claims struct {
		Issuer     string `json:"iss"`
		Audience   string `json:"aud"`
		Expiry     int64  `json:"exp"`
		NotBefore  int64  `json:"nbf"`
		ServiceURL string `json:"serviceurl"`
	}
	if json.Unmarshal(payload, &claims) != nil {
		return errForbidden
	}
	now := time.Now().Unix()
	if claims.Issuer != "https://api.botframework.com" || claims.Audience != c.ApplicationID || claims.Expiry == 0 || claims.Expiry < now-300 || claims.NotBefore == 0 || claims.NotBefore > now+300 {
		return errForbidden
	}
	var activity struct {
		ServiceURL string `json:"serviceUrl"`
		Channel    string `json:"channelId"`
	}
	if json.Unmarshal(body, &activity) != nil || activity.Channel != "msteams" || claims.ServiceURL != activity.ServiceURL || strings.TrimRight(activity.ServiceURL, "/") != strings.TrimRight(c.ServiceURL, "/") {
		return errForbidden
	}
	key, err := s.teamsKey(ctx, h.Kid)
	if err != nil {
		return err
	}
	if !slices.Contains(key.Endorsements, "msteams") {
		return errForbidden
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return errForbidden
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	return rsa.VerifyPKCS1v15(key.Key, crypto.SHA256, digest[:], signature)
}

func (s *Service) teamsKey(ctx context.Context, kid string) (teamKey, error) {
	s.teamsMu.Lock()
	defer s.teamsMu.Unlock()
	if time.Now().Before(s.teamsKeysUntil) {
		if key, ok := s.teamsKeys[kid]; ok {
			return key, nil
		}
		// Refresh an unfamiliar signing key promptly, while bounding forged-kid
		// requests so they cannot force an unbounded discovery fetch loop.
		if time.Now().Before(s.teamsRefreshAt) {
			return teamKey{}, errForbidden
		}
	}
	s.teamsRefreshAt = time.Now().Add(time.Minute)
	// Pin discovery and key origins. No untrusted JWT field controls a fetch URL.
	get := func(endpoint string, out any) error {
		req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
		if err != nil {
			return err
		}
		resp, err := s.http.Do(req)
		if err != nil {
			return errors.New("Teams signing keys are unavailable")
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return errors.New("Teams signing keys are unavailable")
		}
		return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out)
	}
	var metadata struct {
		Issuer     string   `json:"issuer"`
		Keys       string   `json:"jwks_uri"`
		Algorithms []string `json:"id_token_signing_alg_values_supported"`
	}
	if err := get("https://login.botframework.com/v1/.well-known/openidconfiguration", &metadata); err != nil {
		return teamKey{}, err
	}
	u, err := url.Parse(metadata.Keys)
	if err != nil || u.Scheme != "https" || u.Host != "login.botframework.com" || u.User != nil || metadata.Issuer != "https://api.botframework.com" || !slices.Contains(metadata.Algorithms, "RS256") {
		return teamKey{}, errForbidden
	}
	var keys struct {
		Keys []struct {
			ID           string   `json:"kid"`
			Type         string   `json:"kty"`
			N            string   `json:"n"`
			E            string   `json:"e"`
			Endorsements []string `json:"endorsements"`
		} `json:"keys"`
	}
	if err := get(metadata.Keys, &keys); err != nil {
		return teamKey{}, err
	}
	s.teamsKeys = map[string]teamKey{}
	for _, key := range keys.Keys {
		n, errN := base64.RawURLEncoding.DecodeString(key.N)
		e, errE := base64.RawURLEncoding.DecodeString(key.E)
		if key.Type != "RSA" || errN != nil || errE != nil || len(n) < 256 || len(e) > 4 {
			continue
		}
		exponent := new(big.Int).SetBytes(e).Int64()
		if exponent < 3 || exponent%2 == 0 {
			continue
		}
		s.teamsKeys[key.ID] = teamKey{&rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(exponent)}, key.Endorsements}
	}
	s.teamsKeysUntil = time.Now().Add(time.Hour)
	key, ok := s.teamsKeys[kid]
	if !ok {
		return teamKey{}, errForbidden
	}
	return key, nil
}

func (s *Service) teamsToken(ctx context.Context, c savedConnection) (string, error) {
	s.teamsMu.Lock()
	defer s.teamsMu.Unlock()
	if token := s.tokens[c.ID]; time.Now().Before(token.Until) {
		return token.Value, nil
	}
	form := url.Values{"grant_type": {"client_credentials"}, "client_id": {c.ApplicationID}, "client_secret": {c.Secrets.ClientSecret}, "scope": {"https://api.botframework.com/.default"}}
	endpoint := "https://login.microsoftonline.com/" + url.PathEscape(c.WorkspaceID) + "/oauth2/v2.0/token"
	req, err := http.NewRequestWithContext(ctx, "POST", endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := s.http.Do(req)
	if err != nil {
		return "", errors.New("Teams authentication failed")
	}
	defer resp.Body.Close()
	var token struct {
		Access  string `json:"access_token"`
		Expires int    `json:"expires_in"`
	}
	if resp.StatusCode != 200 || json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&token) != nil || token.Access == "" {
		return "", errors.New("Teams authentication failed; check application credentials")
	}
	s.tokens[c.ID] = accessToken{token.Access, time.Now().Add(time.Duration(max(0, token.Expires-120)) * time.Second)}
	return token.Access, nil
}
