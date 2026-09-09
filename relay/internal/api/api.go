// Package api is the relay's HTTP surface (docs/RELAY-DESIGN.md).
package api

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"fieldnotes/relay/internal/control"
	"fieldnotes/relay/internal/license"
	"fieldnotes/relay/internal/store"
)

// MaxObject is the largest object a device may put: a batch is text, a
// photo a few megabytes; a video, someday, is what this is for.
const MaxObject = 64 << 20

type Server struct {
	DB      *control.DB
	Store   store.ObjectStore
	PubKey  ed25519.PublicKey // organization keys; nil disables licences
	Log     *slog.Logger
	Now     func() time.Time
	Timeout time.Duration
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("POST /v1/properties", s.createProperty)
	mux.HandleFunc("POST /v1/join", s.join)
	mux.HandleFunc("GET /v1/properties/{p}", s.member(s.propertyInfo))
	mux.HandleFunc("POST /v1/properties/{p}/organization", s.member(s.attachOrganization))
	mux.HandleFunc("POST /v1/properties/{p}/join-codes", s.member(s.createJoinCode))
	mux.HandleFunc("GET /v1/properties/{p}/members", s.member(s.members))
	mux.HandleFunc("DELETE /v1/properties/{p}/members/{m}", s.member(s.removeMember))
	mux.HandleFunc("POST /v1/properties/{p}/devices", s.member(s.registerDevice))
	mux.HandleFunc("GET /v1/properties/{p}/store", s.member(s.listObjects))
	mux.HandleFunc("HEAD /v1/properties/{p}/store/{path...}", s.member(s.headObject))
	mux.HandleFunc("GET /v1/properties/{p}/store/{path...}", s.member(s.getObject))
	mux.HandleFunc("PUT /v1/properties/{p}/store/{path...}", s.member(s.putObject))
	mux.HandleFunc("DELETE /v1/properties/{p}/store/{path...}", s.member(s.deleteObject))
	return mux
}

// ── plumbing ──────────────────────────────────────────────────────

type memberHandler func(w http.ResponseWriter, r *http.Request, m *control.Member, p *control.Property)

// member authenticates the bearer token and binds it to the property in
// the path: a token for one property is nothing on another.
func (s *Server) member(h memberHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if tok == "" || tok == r.Header.Get("Authorization") {
			s.fail(w, http.StatusUnauthorized, "This device holds no token for the property.")
			return
		}
		m, err := s.DB.Authenticate(r.Context(), tok)
		if errors.Is(err, control.ErrNotFound) {
			s.fail(w, http.StatusUnauthorized, "This device is no longer a member of the property — ask the owner for a new join code.")
			return
		}
		if err != nil {
			s.oops(w, err)
			return
		}
		if m.PropertyID != r.PathValue("p") {
			s.fail(w, http.StatusNotFound, "Not found on the relay.")
			return
		}
		p, err := s.DB.Property(r.Context(), m.PropertyID)
		if err != nil {
			s.oops(w, err)
			return
		}
		h(w, r, m, p)
	}
}

func (s *Server) fail(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func (s *Server) oops(w http.ResponseWriter, err error) {
	s.Log.Error("relay", "err", err)
	s.fail(w, http.StatusInternalServerError, "The relay is having trouble. Try later.")
}

func (s *Server) ok(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func decode(r *http.Request, v any) error {
	return json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v)
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// ── control plane ─────────────────────────────────────────────────

type membershipOut struct {
	Property struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"property"`
	MemberToken string         `json:"member_token"`
	Role        string         `json:"role"`
	Badge       *license.Badge `json:"badge,omitempty"`
}

func (s *Server) badgeOf(ctx context.Context, p *control.Property) *license.Badge {
	if !p.OrgID.Valid {
		return nil
	}
	o, err := s.DB.Organization(ctx, p.OrgID.String)
	if err != nil {
		return nil
	}
	return &license.Badge{Name: o.BadgeName, Mark: o.BadgeMark}
}

// verifyOrg checks an organization key and records it. Returns its id.
func (s *Server) verifyOrg(ctx context.Context, key string) (string, error) {
	if s.PubKey == nil {
		return "", errors.New("this relay does not accept organization keys")
	}
	p, err := license.Verify(s.PubKey, key, s.now())
	if err != nil {
		return "", err
	}
	o := control.Organization{ID: p.ID, Name: p.Org, BadgeName: p.Badge.Name, BadgeMark: p.Badge.Mark, Seats: p.Seats, ExpiresAt: p.ExpiresAt}
	if o.BadgeName == "" {
		o.BadgeName = p.Org
	}
	return p.ID, s.DB.UpsertOrganization(ctx, o, key)
}

func (s *Server) createProperty(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ID, Name, DisplayName, Email, DeviceID, DeviceLabel, OrgKey string
	}
	var raw struct {
		ID          string `json:"id"`
		Name        string `json:"name"`
		DisplayName string `json:"display_name"`
		Email       string `json:"email"`
		DeviceID    string `json:"device_id"`
		DeviceLabel string `json:"device_label"`
		OrgKey      string `json:"org_key"`
	}
	if err := decode(r, &raw); err != nil || raw.ID == "" || raw.Name == "" || raw.DisplayName == "" {
		s.fail(w, http.StatusBadRequest, "A property needs an id, a name, and who you are.")
		return
	}
	in = struct{ ID, Name, DisplayName, Email, DeviceID, DeviceLabel, OrgKey string }(raw)
	orgID := ""
	if in.OrgKey != "" {
		id, err := s.verifyOrg(r.Context(), in.OrgKey)
		if err != nil {
			s.fail(w, http.StatusForbidden, "Organization key: "+err.Error())
			return
		}
		orgID = id
	}
	token, m, err := s.DB.CreateProperty(r.Context(), in.ID, in.Name, orgID, in.DisplayName, in.Email, in.DeviceID, in.DeviceLabel)
	if errors.Is(err, control.ErrConflict) {
		s.fail(w, http.StatusConflict, control.Describe(err, 0, 0))
		return
	}
	if err != nil {
		s.oops(w, err)
		return
	}
	p, _ := s.DB.Property(r.Context(), in.ID)
	var out membershipOut
	out.Property.ID, out.Property.Name = in.ID, in.Name
	out.MemberToken, out.Role = token, m.Role
	out.Badge = s.badgeOf(r.Context(), p)
	s.ok(w, out)
}

func (s *Server) join(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Code        string `json:"code"`
		DisplayName string `json:"display_name"`
		Email       string `json:"email"`
		DeviceID    string `json:"device_id"`
		DeviceLabel string `json:"device_label"`
	}
	if err := decode(r, &in); err != nil || in.Code == "" || in.DisplayName == "" {
		s.fail(w, http.StatusBadRequest, "Joining needs the code and your name.")
		return
	}
	token, p, m, err := s.DB.Join(r.Context(), in.Code, in.DisplayName, in.Email, in.DeviceID, in.DeviceLabel)
	switch {
	case errors.Is(err, control.ErrCodeStale):
		s.fail(w, http.StatusNotFound, control.Describe(err, 0, 0))
		return
	case errors.Is(err, control.ErrSeatsFull):
		// p may be nil when the code is fine but the seats are not.
		used, allowed := 0, control.FreeSeats
		if p != nil {
			used, allowed, _, _ = s.DB.Seats(r.Context(), p)
		}
		s.fail(w, http.StatusForbidden, control.Describe(err, used, allowed))
		return
	case err != nil:
		s.oops(w, err)
		return
	}
	var out membershipOut
	out.Property.ID, out.Property.Name = p.ID, p.Name
	out.MemberToken, out.Role = token, m.Role
	out.Badge = s.badgeOf(r.Context(), p)
	s.ok(w, out)
}

func (s *Server) propertyInfo(w http.ResponseWriter, r *http.Request, m *control.Member, p *control.Property) {
	used, allowed, org, err := s.DB.Seats(r.Context(), p)
	if err != nil {
		s.oops(w, err)
		return
	}
	out := map[string]any{
		"id": p.ID, "name": p.Name, "role": m.Role,
		"seats": map[string]int{"used": used, "allowed": allowed},
	}
	if org != nil {
		out["organization"] = map[string]any{"name": org.Name, "expires_at": org.ExpiresAt}
		out["badge"] = license.Badge{Name: org.BadgeName, Mark: org.BadgeMark}
	}
	s.ok(w, out)
}

func (s *Server) attachOrganization(w http.ResponseWriter, r *http.Request, m *control.Member, p *control.Property) {
	if m.Role != "owner" {
		s.fail(w, http.StatusForbidden, "Only the owner may put a property under an organization.")
		return
	}
	var in struct {
		OrgKey string `json:"org_key"`
	}
	if err := decode(r, &in); err != nil || in.OrgKey == "" {
		s.fail(w, http.StatusBadRequest, "An organization key is needed.")
		return
	}
	id, err := s.verifyOrg(r.Context(), in.OrgKey)
	if err != nil {
		s.fail(w, http.StatusForbidden, "Organization key: "+err.Error())
		return
	}
	if err := s.DB.AttachOrganization(r.Context(), p.ID, id); err != nil {
		s.oops(w, err)
		return
	}
	p, _ = s.DB.Property(r.Context(), p.ID)
	s.propertyInfo(w, r, m, p)
}

func (s *Server) createJoinCode(w http.ResponseWriter, r *http.Request, m *control.Member, p *control.Property) {
	if m.Role != "owner" {
		s.fail(w, http.StatusForbidden, "Only the owner may invite.")
		return
	}
	var in struct {
		Role       string `json:"role"`
		Email      string `json:"email"`
		TTLSeconds int    `json:"ttl_seconds"`
	}
	if err := decode(r, &in); err != nil {
		s.fail(w, http.StatusBadRequest, "Bad invite.")
		return
	}
	if in.Role == "" {
		in.Role = "editor"
	}
	ttl := time.Duration(in.TTLSeconds) * time.Second
	if ttl <= 0 || ttl > 30*24*time.Hour {
		ttl = 7 * 24 * time.Hour
	}
	code, exp, err := s.DB.CreateJoinCode(r.Context(), p, in.Role, in.Email, m.ID, ttl)
	switch {
	case errors.Is(err, control.ErrSeatsFull):
		used, allowed, _, _ := s.DB.Seats(r.Context(), p)
		s.fail(w, http.StatusForbidden, control.Describe(err, used, allowed))
		return
	case errors.Is(err, control.ErrBadRequest):
		s.fail(w, http.StatusBadRequest, "A code seats an editor or a viewer.")
		return
	case err != nil:
		s.oops(w, err)
		return
	}
	s.ok(w, map[string]string{"code": code, "expires_at": exp})
}

func (s *Server) members(w http.ResponseWriter, r *http.Request, _ *control.Member, p *control.Property) {
	ms, err := s.DB.Members(r.Context(), p.ID)
	if err != nil {
		s.oops(w, err)
		return
	}
	out := make([]map[string]any, 0, len(ms))
	for _, m := range ms {
		row := map[string]any{"id": m.ID, "display_name": m.DisplayName, "role": m.Role, "devices": m.Devices}
		if m.Email.Valid {
			row["email"] = m.Email.String
		}
		out = append(out, row)
	}
	s.ok(w, map[string]any{"members": out})
}

func (s *Server) removeMember(w http.ResponseWriter, r *http.Request, m *control.Member, p *control.Property) {
	if m.Role != "owner" {
		s.fail(w, http.StatusForbidden, "Only the owner may remove a member.")
		return
	}
	err := s.DB.RemoveMember(r.Context(), p.ID, r.PathValue("m"))
	if errors.Is(err, control.ErrNotFound) {
		s.fail(w, http.StatusNotFound, "No such member, or the owner.")
		return
	}
	if err != nil {
		s.oops(w, err)
		return
	}
	s.ok(w, map[string]string{})
}

func (s *Server) registerDevice(w http.ResponseWriter, r *http.Request, m *control.Member, _ *control.Property) {
	var in struct {
		DeviceID string `json:"device_id"`
		Label    string `json:"label"`
	}
	if err := decode(r, &in); err != nil || in.DeviceID == "" {
		s.fail(w, http.StatusBadRequest, "A device id is needed.")
		return
	}
	if err := s.DB.TouchDevice(r.Context(), m.ID, in.DeviceID, in.Label); err != nil {
		s.oops(w, err)
		return
	}
	s.ok(w, map[string]string{})
}

// ── store ─────────────────────────────────────────────────────────

const root = "fieldnotes/"

func objectKey(p *control.Property, path string) string { return p.ID + "/" + path }

// mayWrite is the layout rule the whole design leans on: a device writes
// only under its own sync dir; blobs are content-addressed and anyone's;
// the manifest (the keyring envelope) is the owner's alone.
func mayWrite(m *control.Member, path string) bool {
	if m.Role == "viewer" || !strings.HasPrefix(path, root) {
		return false
	}
	rest := path[len(root):]
	if strings.HasPrefix(rest, "blobs/") {
		return true
	}
	if rest == "manifest.json" {
		return m.Role == "owner"
	}
	if strings.HasPrefix(rest, "sync/") {
		for _, d := range m.Devices {
			if d != "" && strings.HasPrefix(rest, "sync/"+d+"/") {
				return true
			}
		}
	}
	return false
}

func cleanPath(raw string) (string, bool) {
	if raw == "" || strings.Contains(raw, "..") || strings.HasPrefix(raw, "/") || !strings.HasPrefix(raw, root) {
		return "", false
	}
	return raw, true
}

func (s *Server) listObjects(w http.ResponseWriter, r *http.Request, _ *control.Member, p *control.Property) {
	prefix := r.URL.Query().Get("prefix")
	if strings.Contains(prefix, "..") {
		s.fail(w, http.StatusBadRequest, "Bad prefix.")
		return
	}
	keys, err := s.Store.List(r.Context(), p.ID+"/"+prefix)
	if err != nil {
		s.oops(w, err)
		return
	}
	names := make([]string, 0, len(keys))
	for _, k := range keys {
		names = append(names, strings.TrimPrefix(k, p.ID+"/"))
	}
	s.ok(w, map[string]any{"names": names})
}

func (s *Server) headObject(w http.ResponseWriter, r *http.Request, _ *control.Member, p *control.Property) {
	path, ok := cleanPath(r.PathValue("path"))
	if !ok {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	exists, err := s.Store.Head(r.Context(), objectKey(p, path))
	if err != nil {
		s.oops(w, err)
		return
	}
	if !exists {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (s *Server) getObject(w http.ResponseWriter, r *http.Request, _ *control.Member, p *control.Property) {
	path, ok := cleanPath(r.PathValue("path"))
	if !ok {
		s.fail(w, http.StatusBadRequest, "Bad path.")
		return
	}
	body, size, err := s.Store.Get(r.Context(), objectKey(p, path))
	if errors.Is(err, store.ErrNotFound) {
		s.fail(w, http.StatusNotFound, "Not found on the relay.")
		return
	}
	if err != nil {
		s.oops(w, err)
		return
	}
	defer body.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	if size > 0 {
		w.Header().Set("Content-Length", itoa(size))
	}
	io.Copy(w, body)
}

func (s *Server) putObject(w http.ResponseWriter, r *http.Request, m *control.Member, p *control.Property) {
	path, ok := cleanPath(r.PathValue("path"))
	if !ok {
		s.fail(w, http.StatusBadRequest, "Bad path.")
		return
	}
	if !mayWrite(m, path) {
		s.fail(w, http.StatusForbidden, "A device writes only under its own sync folder, blobs, and — the owner — the manifest.")
		return
	}
	if r.ContentLength > MaxObject {
		s.fail(w, http.StatusRequestEntityTooLarge, "Too large for the relay.")
		return
	}
	body := http.MaxBytesReader(w, r.Body, MaxObject)
	if err := s.Store.Put(r.Context(), objectKey(p, path), body, r.ContentLength); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			s.fail(w, http.StatusRequestEntityTooLarge, "Too large for the relay.")
			return
		}
		s.oops(w, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

func (s *Server) deleteObject(w http.ResponseWriter, r *http.Request, m *control.Member, p *control.Property) {
	path, ok := cleanPath(r.PathValue("path"))
	if !ok {
		s.fail(w, http.StatusBadRequest, "Bad path.")
		return
	}
	// The owner prunes; a device may withdraw its own batches.
	if m.Role != "owner" && !mayWrite(m, path) {
		s.fail(w, http.StatusForbidden, "Only the owner deletes here.")
		return
	}
	if err := s.Store.Delete(r.Context(), objectKey(p, path)); err != nil {
		s.oops(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func itoa(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}
