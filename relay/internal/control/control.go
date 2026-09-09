// Package control is the relay's control plane (docs/RELAY-DESIGN.md):
// organizations, properties, members, devices and join codes, in SQLite.
// This is the part the relay keeps in the clear, because it is the part
// that has to be true for seats and attribution.
package control

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

var (
	ErrNotFound   = errors.New("not found")
	ErrForbidden  = errors.New("forbidden")
	ErrSeatsFull  = errors.New("seats full")
	ErrCodeStale  = errors.New("that code is not valid")
	ErrConflict   = errors.New("already exists")
	ErrBadRequest = errors.New("bad request")
)

// FreeSeats is what a property with no organization may hold (D-030).
const FreeSeats = 2

type DB struct{ sql *sql.DB }

func Open(path string) (*DB, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}
	return &DB{sql: db}, nil
}

func (d *DB) Close() error { return d.sql.Close() }

const schema = `
CREATE TABLE IF NOT EXISTS organizations (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, badge_name TEXT NOT NULL,
  badge_mark TEXT, seats INTEGER NOT NULL, expires_at TEXT,
  license TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS properties (
  id TEXT PRIMARY KEY, name TEXT NOT NULL,
  org_id TEXT REFERENCES organizations(id), created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS members (
  id TEXT PRIMARY KEY, property_id TEXT NOT NULL REFERENCES properties(id),
  email TEXT, display_name TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner','editor','viewer')),
  token_hash TEXT NOT NULL UNIQUE, joined_at TEXT NOT NULL, removed_at TEXT
);
CREATE TABLE IF NOT EXISTS devices (
  id TEXT NOT NULL, member_id TEXT NOT NULL REFERENCES members(id),
  label TEXT, last_seen_at TEXT NOT NULL, PRIMARY KEY (id, member_id)
);
CREATE TABLE IF NOT EXISTS join_codes (
  code TEXT PRIMARY KEY, property_id TEXT NOT NULL REFERENCES properties(id),
  role TEXT NOT NULL, email TEXT, expires_at TEXT NOT NULL,
  uses_left INTEGER NOT NULL, created_by TEXT NOT NULL
);
`

type Organization struct {
	ID, Name, BadgeName, BadgeMark string
	Seats                          int
	ExpiresAt                      string
}

type Property struct {
	ID, Name string
	OrgID    sql.NullString
}

type Member struct {
	ID, PropertyID, DisplayName, Role string
	Email                             sql.NullString
	Devices                           []string
}

func now() string { return time.Now().UTC().Format(time.RFC3339Nano) }

func newID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// NewToken is 32 random bytes, base64url; only its hash is stored.
func NewToken() (token, hash string) {
	b := make([]byte, 32)
	rand.Read(b)
	token = base64.RawURLEncoding.EncodeToString(b)
	return token, hashToken(token)
}

func hashToken(t string) string {
	h := sha256.Sum256([]byte(t))
	return hex.EncodeToString(h[:])
}

// ── organizations ─────────────────────────────────────────────────

// UpsertOrganization records a verified licence; the same licence id
// re-entered updates seats and badge.
func (d *DB) UpsertOrganization(ctx context.Context, o Organization, license string) error {
	_, err := d.sql.ExecContext(ctx, `INSERT INTO organizations
	  (id, name, badge_name, badge_mark, seats, expires_at, license, created_at)
	  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	  ON CONFLICT(id) DO UPDATE SET name=excluded.name, badge_name=excluded.badge_name,
	    badge_mark=excluded.badge_mark, seats=excluded.seats,
	    expires_at=excluded.expires_at, license=excluded.license`,
		o.ID, o.Name, o.BadgeName, nullIfEmpty(o.BadgeMark), o.Seats, nullIfEmpty(o.ExpiresAt), license, now())
	return err
}

func (d *DB) Organization(ctx context.Context, id string) (*Organization, error) {
	var o Organization
	var mark, exp sql.NullString
	err := d.sql.QueryRowContext(ctx, `SELECT id, name, badge_name, badge_mark, seats, expires_at
	  FROM organizations WHERE id = ?`, id).Scan(&o.ID, &o.Name, &o.BadgeName, &mark, &o.Seats, &exp)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	o.BadgeMark, o.ExpiresAt = mark.String, exp.String
	return &o, err
}

// ── properties ────────────────────────────────────────────────────

// CreateProperty puts a property on the relay under the owner's local id
// and seats the owner. Returns the owner's token.
func (d *DB) CreateProperty(ctx context.Context, id, name, orgID, displayName, email, deviceID, deviceLabel string) (token string, member *Member, err error) {
	tx, err := d.sql.BeginTx(ctx, nil)
	if err != nil {
		return "", nil, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO properties (id, name, org_id, created_at) VALUES (?, ?, ?, ?)`,
		id, name, nullIfEmpty(orgID), now()); err != nil {
		if strings.Contains(err.Error(), "UNIQUE") || strings.Contains(err.Error(), "constraint") {
			return "", nil, ErrConflict
		}
		return "", nil, err
	}
	token, hash := NewToken()
	m := &Member{ID: newID(), PropertyID: id, DisplayName: displayName, Role: "owner", Email: nullString(email)}
	if _, err := tx.ExecContext(ctx, `INSERT INTO members (id, property_id, email, display_name, role, token_hash, joined_at)
	  VALUES (?, ?, ?, ?, 'owner', ?, ?)`, m.ID, id, m.Email, displayName, hash, now()); err != nil {
		return "", nil, err
	}
	if deviceID != "" {
		if _, err := tx.ExecContext(ctx, `INSERT INTO devices (id, member_id, label, last_seen_at) VALUES (?, ?, ?, ?)`,
			deviceID, m.ID, nullIfEmpty(deviceLabel), now()); err != nil {
			return "", nil, err
		}
		m.Devices = []string{deviceID}
	}
	return token, m, tx.Commit()
}

func (d *DB) Property(ctx context.Context, id string) (*Property, error) {
	var p Property
	err := d.sql.QueryRowContext(ctx, `SELECT id, name, org_id FROM properties WHERE id = ?`, id).Scan(&p.ID, &p.Name, &p.OrgID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return &p, err
}

// AttachOrganization puts an existing property under a licence.
func (d *DB) AttachOrganization(ctx context.Context, propertyID, orgID string) error {
	res, err := d.sql.ExecContext(ctx, `UPDATE properties SET org_id = ? WHERE id = ?`, orgID, propertyID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// ── members ───────────────────────────────────────────────────────

// Authenticate resolves a bearer token to its live member.
func (d *DB) Authenticate(ctx context.Context, token string) (*Member, error) {
	var m Member
	err := d.sql.QueryRowContext(ctx, `SELECT id, property_id, display_name, role, email FROM members
	  WHERE token_hash = ? AND removed_at IS NULL`, hashToken(token)).Scan(&m.ID, &m.PropertyID, &m.DisplayName, &m.Role, &m.Email)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	m.Devices, err = d.devicesOf(ctx, m.ID)
	return &m, err
}

func (d *DB) devicesOf(ctx context.Context, memberID string) ([]string, error) {
	rows, err := d.sql.QueryContext(ctx, `SELECT id FROM devices WHERE member_id = ? ORDER BY last_seen_at`, memberID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func (d *DB) Members(ctx context.Context, propertyID string) ([]Member, error) {
	rows, err := d.sql.QueryContext(ctx, `SELECT id, property_id, display_name, role, email FROM members
	  WHERE property_id = ? AND removed_at IS NULL ORDER BY joined_at`, propertyID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Member
	for rows.Next() {
		var m Member
		if err := rows.Scan(&m.ID, &m.PropertyID, &m.DisplayName, &m.Role, &m.Email); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range out {
		if out[i].Devices, err = d.devicesOf(ctx, out[i].ID); err != nil {
			return nil, err
		}
	}
	if out == nil {
		out = []Member{}
	}
	return out, nil
}

// RemoveMember ends a seat: the token stops working at once.
func (d *DB) RemoveMember(ctx context.Context, propertyID, memberID string) error {
	res, err := d.sql.ExecContext(ctx, `UPDATE members SET removed_at = ? WHERE id = ? AND property_id = ? AND removed_at IS NULL AND role != 'owner'`,
		now(), memberID, propertyID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (d *DB) TouchDevice(ctx context.Context, memberID, deviceID, label string) error {
	_, err := d.sql.ExecContext(ctx, `INSERT INTO devices (id, member_id, label, last_seen_at) VALUES (?, ?, ?, ?)
	  ON CONFLICT(id, member_id) DO UPDATE SET last_seen_at = excluded.last_seen_at,
	    label = COALESCE(excluded.label, devices.label)`, deviceID, memberID, nullIfEmpty(label), now())
	return err
}

// ── seats ─────────────────────────────────────────────────────────

// Seats reports used and allowed for a property. Without an organization,
// seats are members of this property against FreeSeats. Under one, seats
// are distinct people (by email, else member) across the organization's
// properties against its licence.
func (d *DB) Seats(ctx context.Context, p *Property) (used, allowed int, org *Organization, err error) {
	if !p.OrgID.Valid {
		err = d.sql.QueryRowContext(ctx, `SELECT COUNT(*) FROM members WHERE property_id = ? AND removed_at IS NULL`, p.ID).Scan(&used)
		return used, FreeSeats, nil, err
	}
	org, err = d.Organization(ctx, p.OrgID.String)
	if err != nil {
		return 0, 0, nil, err
	}
	err = d.sql.QueryRowContext(ctx, `SELECT COUNT(DISTINCT COALESCE(m.email, m.id)) FROM members m
	  JOIN properties p ON p.id = m.property_id
	  WHERE p.org_id = ? AND m.removed_at IS NULL`, p.OrgID.String).Scan(&used)
	return used, org.Seats, org, err
}

// wouldExceed says whether seating [email] on p goes past the allowance.
// A person already seated elsewhere in the organization costs nothing.
func (d *DB) wouldExceed(ctx context.Context, p *Property, email string) (bool, error) {
	used, allowed, org, err := d.Seats(ctx, p)
	if err != nil {
		return false, err
	}
	if org != nil && org.ExpiresAt != "" {
		if exp, perr := time.Parse(time.RFC3339, org.ExpiresAt); perr == nil && time.Now().After(exp) {
			return true, nil
		}
	}
	if org != nil && email != "" {
		var n int
		if err := d.sql.QueryRowContext(ctx, `SELECT COUNT(*) FROM members m JOIN properties p ON p.id = m.property_id
		  WHERE p.org_id = ? AND m.removed_at IS NULL AND m.email = ?`, org.ID, email).Scan(&n); err != nil {
			return false, err
		}
		if n > 0 {
			return false, nil
		}
	}
	return used+1 > allowed, nil
}

// ── join codes ────────────────────────────────────────────────────

func (d *DB) CreateJoinCode(ctx context.Context, p *Property, role, email, createdBy string, ttl time.Duration) (code, expiresAt string, err error) {
	if role != "editor" && role != "viewer" {
		return "", "", ErrBadRequest
	}
	if full, err := d.wouldExceed(ctx, p, email); err != nil {
		return "", "", err
	} else if full {
		return "", "", ErrSeatsFull
	}
	b := make([]byte, 5)
	rand.Read(b)
	// Eight letters and digits a person can read out loud.
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var sb strings.Builder
	for i := 0; i < 8; i++ {
		sb.WriteByte(alphabet[int(b[i%5]>>uint(i%3))%len(alphabet)])
		b[i%5] = b[i%5]*7 + 13
	}
	code = sb.String()
	expiresAt = time.Now().UTC().Add(ttl).Format(time.RFC3339)
	_, err = d.sql.ExecContext(ctx, `INSERT INTO join_codes (code, property_id, role, email, expires_at, uses_left, created_by)
	  VALUES (?, ?, ?, ?, ?, 1, ?)`, code, p.ID, role, nullIfEmpty(email), expiresAt, createdBy)
	return code, expiresAt, err
}

// Join seats a person from a code. The code is spent; the seat is checked
// again here, because two codes can be handed out for one seat. The reads
// run before the transaction: the pool holds one connection, and a query
// through the pool while a transaction is open would wait on itself.
func (d *DB) Join(ctx context.Context, code, displayName, email, deviceID, deviceLabel string) (token string, p *Property, m *Member, err error) {
	code = strings.ToUpper(strings.TrimSpace(code))
	var propertyID, role, expires string
	var codeEmail sql.NullString
	var uses int
	err = d.sql.QueryRowContext(ctx, `SELECT property_id, role, email, expires_at, uses_left FROM join_codes WHERE code = ?`, code).
		Scan(&propertyID, &role, &codeEmail, &expires, &uses)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil, nil, ErrCodeStale
	}
	if err != nil {
		return "", nil, nil, err
	}
	if exp, perr := time.Parse(time.RFC3339, expires); perr != nil || time.Now().After(exp) || uses <= 0 {
		return "", nil, nil, ErrCodeStale
	}
	if codeEmail.Valid && email == "" {
		email = codeEmail.String
	}
	p, err = d.Property(ctx, propertyID)
	if err != nil {
		return "", nil, nil, err
	}
	if full, err := d.wouldExceed(ctx, p, email); err != nil {
		return "", nil, nil, err
	} else if full {
		return "", p, nil, ErrSeatsFull
	}
	tx, err := d.sql.BeginTx(ctx, nil)
	if err != nil {
		return "", nil, nil, err
	}
	defer tx.Rollback()
	// Spend the code first; a second joiner racing on the same code loses.
	res, err := tx.ExecContext(ctx, `UPDATE join_codes SET uses_left = uses_left - 1 WHERE code = ? AND uses_left > 0`, code)
	if err != nil {
		return "", nil, nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return "", nil, nil, ErrCodeStale
	}
	token, hash := NewToken()
	m = &Member{ID: newID(), PropertyID: propertyID, DisplayName: displayName, Role: role, Email: nullString(email)}
	if _, err := tx.ExecContext(ctx, `INSERT INTO members (id, property_id, email, display_name, role, token_hash, joined_at)
	  VALUES (?, ?, ?, ?, ?, ?, ?)`, m.ID, propertyID, m.Email, displayName, role, hash, now()); err != nil {
		return "", nil, nil, err
	}
	if deviceID != "" {
		if _, err := tx.ExecContext(ctx, `INSERT INTO devices (id, member_id, label, last_seen_at) VALUES (?, ?, ?, ?)`,
			deviceID, m.ID, nullIfEmpty(deviceLabel), now()); err != nil {
			return "", nil, nil, err
		}
		m.Devices = []string{deviceID}
	}
	return token, p, m, tx.Commit()
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullString(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }

// Describe turns a control error into the sentence the app shows.
func Describe(err error, used, allowed int) string {
	switch {
	case errors.Is(err, ErrSeatsFull):
		if allowed == FreeSeats {
			return fmt.Sprintf("Shared with %d people already; the free plan seats %d. An organization key lifts it.", used, allowed)
		}
		return fmt.Sprintf("The organization's %d seats are all taken (%d in use). Remove a member or add seats.", allowed, used)
	case errors.Is(err, ErrCodeStale):
		return "That code is not valid any more — ask the owner for a new one."
	case errors.Is(err, ErrConflict):
		return "That property is already on the relay."
	}
	return err.Error()
}
