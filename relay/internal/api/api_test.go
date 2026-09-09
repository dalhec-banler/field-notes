package api

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"fieldnotes/relay/internal/control"
	"fieldnotes/relay/internal/license"
	"fieldnotes/relay/internal/store"
)

type rig struct {
	t    *testing.T
	srv  *httptest.Server
	priv ed25519.PrivateKey
}

func newRig(t *testing.T) *rig {
	t.Helper()
	dir := t.TempDir()
	db, err := control.Open(filepath.Join(dir, "c.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	s := &Server{DB: db, Store: &store.FS{Root: filepath.Join(dir, "store")}, PubKey: pub, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)
	return &rig{t: t, srv: srv, priv: priv}
}

func (r *rig) do(method, path, token string, body any) (int, map[string]any, []byte) {
	r.t.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		rd = bytes.NewReader(b)
	default:
		j, _ := json.Marshal(b)
		rd = bytes.NewReader(j)
	}
	req, _ := http.NewRequest(method, r.srv.URL+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		r.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var m map[string]any
	json.Unmarshal(raw, &m)
	return res.StatusCode, m, raw
}

func (r *rig) create(id, name, orgKey string) string {
	code, m, raw := r.do("POST", "/v1/properties", "", map[string]any{
		"id": id, "name": name, "display_name": "Austin", "email": "austin@example.com", "device_id": "phone", "org_key": orgKey,
	})
	if code != 200 {
		r.t.Fatalf("create %d %s", code, raw)
	}
	return m["member_token"].(string)
}

func (r *rig) invite(prop, owner, role string) (string, int, string) {
	code, m, raw := r.do("POST", "/v1/properties/"+prop+"/join-codes", owner, map[string]any{"role": role})
	if code != 200 {
		return "", code, string(raw)
	}
	return m["code"].(string), 200, ""
}

func (r *rig) join(code, name, email, device string) (string, int, string) {
	st, m, raw := r.do("POST", "/v1/join", "", map[string]any{"code": code, "display_name": name, "email": email, "device_id": device})
	if st != 200 {
		return "", st, string(raw)
	}
	return m["member_token"].(string), 200, ""
}

func TestCreateInviteJoinAndTheLayoutRule(t *testing.T) {
	r := newRig(t)
	owner := r.create("p1", "Shorts", "")
	code, st, _ := r.invite("p1", owner, "editor")
	if st != 200 {
		t.Fatal("invite", st)
	}
	member, st, _ := r.join(code, "Wylder", "w@example.com", "w-phone")
	if st != 200 {
		t.Fatal("join", st)
	}
	// The code is spent.
	if _, st, _ := r.join(code, "Again", "", "x"); st != 404 {
		t.Fatalf("spent code should be 404, got %d", st)
	}

	// Owner writes under its own sync dir and the manifest; member reads.
	if st, _, raw := r.do("PUT", "/v1/properties/p1/store/sync/phone/000000000001-2.json.enc", owner, []byte("sealed")); st != 201 {
		t.Fatalf("owner put %d %s", st, raw)
	}
	if st, _, _ := r.do("PUT", "/v1/properties/p1/store/fieldnotes/manifest.json", owner, []byte("{}")); st != 201 {
		t.Fatal("owner manifest", st)
	}
	if st, _, raw := r.do("GET", "/v1/properties/p1/store/sync/phone/000000000001-2.json.enc", member, nil); st != 200 || string(raw) != "sealed" {
		t.Fatalf("member get %d %q", st, raw)
	}
	if st, _, _ := r.do("HEAD", "/v1/properties/p1/store/sync/phone/nope", member, nil); st != 404 {
		t.Fatal("head missing", st)
	}
	_, m, _ := r.do("GET", "/v1/properties/p1/store?prefix=sync/", member, nil)
	if names := m["names"].([]any); len(names) != 1 {
		t.Fatalf("list %v", names)
	}

	// The layout rule: not another device's dir, not the manifest; blobs yes.
	if st, _, _ := r.do("PUT", "/v1/properties/p1/store/sync/phone/000000000009-9.json.enc", member, []byte("x")); st != 403 {
		t.Fatal("member into owner's dir should be 403, got", st)
	}
	if st, _, _ := r.do("PUT", "/v1/properties/p1/store/fieldnotes/manifest.json", member, []byte("x")); st != 403 {
		t.Fatal("member manifest should be 403")
	}
	if st, _, _ := r.do("PUT", "/v1/properties/p1/store/sync/w-phone/000000000001-1.json.enc", member, []byte("y")); st != 201 {
		t.Fatal("member own dir")
	}
	if st, _, _ := r.do("PUT", "/v1/properties/p1/store/fieldnotes/blobs/ab/abcd.enc", member, []byte("z")); st != 201 {
		t.Fatal("member blob")
	}
	if st, _, _ := r.do("PUT", "/v1/properties/p1/store/../other/x", member, []byte("z")); st != 400 && st != 404 {
		t.Fatal("path escape", st)
	}

	// A token is nothing on another property.
	r.create("p2", "Home", "")
	if st, _, _ := r.do("GET", "/v1/properties/p2/store?prefix=", member, nil); st != 404 {
		t.Fatal("cross-property token", st)
	}

	// Members registry names people and their devices.
	_, m, _ = r.do("GET", "/v1/properties/p1/members", member, nil)
	if ms := m["members"].([]any); len(ms) != 2 || ms[1].(map[string]any)["display_name"] != "Wylder" {
		t.Fatalf("members %v", ms)
	}
	// Removal kills the token at once.
	memberID := m["members"].([]any)[1].(map[string]any)["id"].(string)
	if st, _, _ := r.do("DELETE", "/v1/properties/p1/members/"+memberID, owner, nil); st != 200 {
		t.Fatal("remove")
	}
	if st, _, _ := r.do("GET", "/v1/properties/p1/store?prefix=", member, nil); st != 401 {
		t.Fatal("removed member should be 401, got", st)
	}
}

func TestTwoSeatsFreeThenAnOrganizationKey(t *testing.T) {
	r := newRig(t)
	owner := r.create("p1", "Shorts", "")
	code, _, _ := r.invite("p1", owner, "editor")
	if _, st, _ := r.join(code, "Second", "two@example.com", "d2"); st != 200 {
		t.Fatal("second seat is free")
	}
	_, st, msg := r.invite("p1", owner, "editor")
	if st != 403 || !strings.Contains(msg, "free plan seats 2") {
		t.Fatalf("third seat should be refused with the count: %d %s", st, msg)
	}

	// An organization key lifts it — and seats count people across properties.
	key, err := license.Sign(r.priv, license.Payload{ID: "org-plateau", Org: "Plateau Land & Wildlife", Seats: 5, Badge: license.Badge{Name: "Plateau"}, IssuedAt: time.Now().UTC().Format(time.RFC3339)})
	if err != nil {
		t.Fatal(err)
	}
	st, m, raw := r.do("POST", "/v1/properties/p1/organization", owner, map[string]any{"org_key": key})
	if st != 200 || m["badge"].(map[string]any)["name"] != "Plateau" {
		t.Fatalf("attach %d %s", st, raw)
	}
	if seats := m["seats"].(map[string]any); seats["allowed"].(float64) != 5 || seats["used"].(float64) != 2 {
		t.Fatalf("seats %v", seats)
	}
	code, st, _ = r.invite("p1", owner, "editor")
	if st != 200 {
		t.Fatal("third seat under licence")
	}
	if _, st, _ := r.join(code, "Third", "three@example.com", "d3"); st != 200 {
		t.Fatal("third joins")
	}
	// The same person on a second property of the organization costs no seat.
	owner2 := r.create("p2", "Client ranch", key)
	code, _, _ = r.invite("p2", owner2, "viewer")
	if _, st, _ := r.join(code, "Third again", "three@example.com", "d3"); st != 200 {
		t.Fatal("same person, second property")
	}
	_, m, _ = r.do("GET", "/v1/properties/p2", owner2, nil)
	if seats := m["seats"].(map[string]any); seats["used"].(float64) != 3 {
		// austin (owner of both, counted once), two, three (on both, counted once)
		t.Fatalf("org-wide seats %v", seats)
	}

	// A bad key is refused in words.
	if st, _, raw := r.do("POST", "/v1/properties/p1/organization", owner, map[string]any{"org_key": "FNL1.nope.nope"}); st != 403 || !strings.Contains(string(raw), "Organization key") {
		t.Fatalf("bad key %d %s", st, raw)
	}
}

func TestViewersRead(t *testing.T) {
	r := newRig(t)
	owner := r.create("p1", "Shorts", "")
	code, _, _ := r.invite("p1", owner, "viewer")
	viewer, _, _ := r.join(code, "Reader", "", "r1")
	r.do("PUT", "/v1/properties/p1/store/sync/phone/000000000001-1.json.enc", owner, []byte("s"))
	if st, _, _ := r.do("GET", "/v1/properties/p1/store/sync/phone/000000000001-1.json.enc", viewer, nil); st != 200 {
		t.Fatal("viewer reads")
	}
	if st, _, _ := r.do("PUT", "/v1/properties/p1/store/sync/r1/000000000001-1.json.enc", viewer, []byte("s")); st != 403 {
		t.Fatal("viewer never writes")
	}
	if st, _, _ := r.do("PUT", "/v1/properties/p1/store/fieldnotes/blobs/aa/bb", viewer, []byte("s")); st != 403 {
		t.Fatal("viewer never writes blobs either")
	}
}
