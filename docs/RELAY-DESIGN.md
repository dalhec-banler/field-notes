# The Field Notes relay — the commercial carrier (D-031)

Status: DESIGN, 2026-09-08. Client target and multi-store sync first
(host-testable against a fake relay), then the service.

## What it is, in one paragraph

A small HTTP service in front of one S3 bucket. A **property** on the
relay is a prefix in that bucket holding the same layout every carrier
holds (`fieldnotes/manifest.json`, `blobs/`, `sync/<device>/…`), all
ciphertext sealed with the property's keyring. The relay never sees a
passphrase or a data key. What it keeps in the clear is the **control
plane**: organizations, their licences, properties, members, devices, and
join codes — because that is the part that has to be true for money to
change hands and for "who wrote this" to be a name.

## Objects

```
organization  id, name, badge_name, badge_mark (png, small), seats, expires_at
property      id, org_id, name, created_by (member), created_at
member        id, property_id, email, display_name, role (owner|editor|viewer),
              token_hash, joined_at, removed_at
device        id (the app's device_id), member_id, label, last_seen_at
join_code     code, property_id, role, email?, expires_at, uses_left, created_by
```

A **seat** is a member with `removed_at IS NULL`. Devices are free: one
person, any number of phones and desks. The relay refuses to create a
join code, or to accept one, when accepting would exceed the
organization's seats. Two seats need no organization at all — the free
allowance exists on the relay too, so a landowner and one other person
can use it without a licence; the licence is what lifts the number and
attaches the badge.

## Authentication

Bearer tokens, random 32 bytes, stored hashed. Two kinds:

- **member token** — issued when a member joins (or creates) a property;
  scoped to that property; carried by every device of that member. Lives
  in the device's prefs beside the Drive grant, never in the database.
- **owner token** — the same thing with role owner; can invite, remove,
  rotate, delete.

No passwords, no accounts of ours: identity is "holds a member token",
bootstrapped from a join code the owner hands over in person or by any
message. Email is a label for attribution, not a login.

## Endpoints

```
POST   /v1/properties                      owner creates; body {name, org_key?}
                                            → {property, member_token}
POST   /v1/properties/{p}/join-codes       owner; body {role, email?, ttl}
                                            → {code, expires_at}
POST   /v1/join                            body {code, display_name, device_id, device_label}
                                            → {property, member_token, badge?}
GET    /v1/properties/{p}                  member; property, org badge, seats used/allowed
GET    /v1/properties/{p}/members          member; the registry (attribution)
DELETE /v1/properties/{p}/members/{m}      owner; removes a seat (their token dies)
POST   /v1/properties/{p}/devices          member; register/refresh this device

GET    /v1/properties/{p}/store?prefix=    member; list object names under prefix
HEAD   /v1/properties/{p}/store/{path}     member; exists
GET    /v1/properties/{p}/store/{path}     member; read (ciphertext)
PUT    /v1/properties/{p}/store/{path}     editor+; write (ciphertext, ≤ 64 MB)
DELETE /v1/properties/{p}/store/{path}     owner, or the writing device under its own sync/<device>/
```

The store endpoints are a `BackupTarget`: `list`, `exists`, `read`,
`write`, `delete`. The relay enforces the layout rule the design relies
on — a device may write only under `sync/<its own device_id>/`, plus
`blobs/` (content-addressed, idempotent) and, for the owner,
`fieldnotes/manifest.json`. Viewers cannot write at all.

## Licences

An **organization key** (D-030) is a signed token; the relay verifies it
with the same public key the app embeds, records the organization, and
from then on the seat count and badge are the relay's to answer. The app
also verifies the key locally so the badge can draw offline. Keys are
issued by `tool/issue_license.dart` with a private key kept outside the
repo (`~/.keystores/fieldnotes-license.key`).

## What the client does

- `RelayTarget implements BackupTarget` — the five store calls over HTTP
  with the member token. Same seal, same layout, same op log.
- `SharedProperties` (prefs) — property_id → {relay_url, member_token,
  role}. Not synced, not backed up: a restored phone rejoins with a code.
- `SyncService` runs the app-folder cycle as today, then one cycle per
  shared property with `SyncScope.property(id)` against its
  `RelayTarget`, sharing the media push/pull code.
- Screens: Share this property (create on relay → join code to hand
  over), Join a shared property (paste code → passphrase → bootstrap
  pull), Members (registry, remove), Organization (enter key, badge
  preview). Attribution: `created_by`/device → member display name.

## Hosting

One Go binary (`relay/`), SQLite for the control plane, S3 for the
store, behind TLS on the smallest instance that runs; or the same binary
on Lambda later. Backups of the control-plane SQLite nightly to the same
bucket. Cost is dominated by nothing: batches are text, media is
deduplicated by content hash, and a consultancy's whole year fits in a
few gigabytes.

## Failure modes, named

- **Relay down:** the app keeps working alone; sync says "the relay is
  not answering" and tries later. Nothing is lost — ops wait in the log.
- **Token revoked (member removed):** 401 → the app stops syncing that
  property, keeps the local copy, says who to ask. The owner rotates the
  key if the removal mattered (SYNC-DESIGN, revocation).
- **Seat limit:** join refused with the count; the owner sees "N of M
  seats" on the property and the organization to buy more from.
- **Two owners' devices writing the manifest:** only the owner role may;
  the owner's devices coordinate through the manifest's generation as
  the backup already does.
