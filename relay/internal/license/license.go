// Package license verifies organization keys (D-030): a small signed
// token the app and the relay both check with the same public key. No
// server issues them at runtime; a tool signs them with a private key
// that never enters the repo.
//
// Format: FNL1.<base64url payload>.<base64url ed25519 signature>
package license

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Payload is what a key says.
type Payload struct {
	ID        string `json:"id"`
	Org       string `json:"org"`
	Seats     int    `json:"seats"`
	Badge     Badge  `json:"badge"`
	IssuedAt  string `json:"issued_at"`
	ExpiresAt string `json:"expires_at,omitempty"` // RFC3339; empty = never
}

// Badge is the white-label mark the organization may put on plates and
// reports (D-030 rule 6). Mark is a small PNG, base64, optional.
type Badge struct {
	Name string `json:"name"`
	Mark string `json:"mark,omitempty"`
}

var (
	ErrFormat    = errors.New("not an organization key")
	ErrSignature = errors.New("the key's signature does not check")
	ErrExpired   = errors.New("the key has expired")
)

const prefix = "FNL1."

// Verify checks the key against pub and returns its payload.
func Verify(pub ed25519.PublicKey, key string, now time.Time) (*Payload, error) {
	key = strings.TrimSpace(key)
	if !strings.HasPrefix(key, prefix) {
		return nil, ErrFormat
	}
	parts := strings.Split(key[len(prefix):], ".")
	if len(parts) != 2 {
		return nil, ErrFormat
	}
	body, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, ErrFormat
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, ErrFormat
	}
	if !ed25519.Verify(pub, []byte(prefix+parts[0]), sig) {
		return nil, ErrSignature
	}
	var p Payload
	if err := json.Unmarshal(body, &p); err != nil {
		return nil, ErrFormat
	}
	if p.ExpiresAt != "" {
		exp, err := time.Parse(time.RFC3339, p.ExpiresAt)
		if err != nil {
			return nil, ErrFormat
		}
		if now.After(exp) {
			return nil, ErrExpired
		}
	}
	if p.Seats <= 0 || p.Org == "" {
		return nil, ErrFormat
	}
	return &p, nil
}

// Sign makes a key. Used by the issuing tool and by tests.
func Sign(priv ed25519.PrivateKey, p Payload) (string, error) {
	body, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	b := base64.RawURLEncoding.EncodeToString(body)
	sig := ed25519.Sign(priv, []byte(prefix+b))
	return prefix + b + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}
