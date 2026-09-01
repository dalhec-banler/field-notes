# Sync & sharing design — serverless, over the stores we already trust

Status: DESIGN — approved direction (Austin, 2026-09-01: "option B, Drive is
the way to go"). No code yet. This document is the thing to argue with.

## The promise this must not break

The audit named the moat: offline-first, no account with us, you own the
data, encrypted at rest, we cannot read it. Sharing is the feature most
likely to quietly destroy all four. So the design constraint, stated once
and used to kill ideas throughout: **no server of ours, ever; nothing
readable leaves a device; the app must keep working alone, offline,
forever, if sharing is never touched or is torn down.**

## Shape of the solution

Sync is a **change log exchanged through a shared blob store** — the same
`BackupTarget` abstraction (Drive / LAN / directory) and the same envelope
encryption the backup engine already uses. No new trust, no new transport,
no new crypto. Google Drive is the default carrier because the plumbing
shipped in D-021; LAN and a plain synced folder come free through the same
interface.

```
owner's phone ──┐                      ┌── contributor's phone
                ├──► shared store ─────┤
desktop ────────┘   (Drive folder,     └── (each device reads all logs,
                     LAN, or folder)        writes only its own)
```

### Why the schema is already ready

Every row table has: UUIDv7 primary keys (no id collisions, time-ordered),
`updated_at` ISO-8601 UTC, `created_by`, and soft deletes via `deleted_at`.
That is, by construction, a mergeable dataset: rows are globally unique,
edits carry their own timestamps, deletes are just edits, and attribution
is built in. Survival is derived, never stored — so the most
conflict-prone number in the app cannot conflict.

## The store layout

Extends the existing backup layout; a sync store and a backup store can be
the same target or different ones.

```
fieldnotes/
  manifest.json            (existing: scheme, wrapped keys)
  blobs/ab/<hmac>          (existing: content-addressed media, encrypted)
  sync/
    <device_id>/
      00000001.log         (encrypted batch of ops, append-only)
      00000002.log
      head                 (highest committed seq for this device)
    members.json           (encrypted: device registry + display names)
```

**The critical property: each device writes only under its own
`sync/<device_id>/`.** Nobody ever writes a file anyone else writes. There
is no locking, no compare-and-swap, no coordination — the entire class of
concurrent-writer bugs is excluded by layout. (The existing backup
generations and blobs remain owner-written; contributors add blobs but
content-addressing makes double-writes idempotent.)

`device_id`: UUIDv7 minted once per install, kept in prefs. Not secret.

## The op log

Each `.log` file is one encrypted batch (same seal as any blob):

```json
{ "v": 1, "device": "<id>", "seq": 17,
  "ops": [
    { "id": "<uuidv7>",              // op id: globally unique, time-ordered
      "hlc": "2026-09-01T20:14:03.112Z-0007-<device>",
      "table": "observations",
      "row": "<row uuid>",
      "cols": { "notes": "...", "updated_at": "..." } }  // full row on insert
  ] }
```

- Ops are **row upserts** carrying changed columns (full row on first
  write). Deletes are upserts of `deleted_at`. There is no "delete op".
- **HLC (hybrid logical clock)** — wall time, a per-device counter, and the
  device id — is the merge key, not raw `updated_at`. Phones' clocks drift;
  a counter guarantees a device's own ops always order correctly, and the
  device id breaks exact ties deterministically on every device.

### Merge rule: row-level last-write-wins

The whole rule: **for each row, the op with the highest HLC wins, column-
merged per op batch.** No CRDTs, no three-way merge, no interactive
conflict UI in v1. Justification, honestly argued:

- The realistic concurrency on a family ranch is *additive* — two people
  capturing different records in different pastures. UUIDv7 keys make
  additive work merge perfectly with no rule at all.
- Same-row races (two people editing one record's notes in the same hour
  offline) are rare, low-stakes, and LWW loses at most one small edit —
  and `created_by`/oplog history means nothing is silently unattributable.
  The losing op is retained in the log; a later "history" view can expose
  it. We are not building Google Docs.
- The genuinely dangerous conflicts (double-counting survival) can't
  happen: check-ins are separate rows (additive), survival is derived.

**One real casualty:** the save-toast UNDO currently hard-erases a record
(`eraseObservation`). Once a record's insert op may already be in a pushed
log, hard-delete becomes a lie other devices won't hear. Change: when sync
is enabled and the op has been pushed, UNDO becomes a tombstone
(`deleted_at`) instead of an erase. When unpushed (the common case —
seconds after capture), erase stays erase and the op is dropped before it
ever leaves.

### Sync cycle (both directions, any trigger)

1. **Push:** write local ops since last push as the next `NNNN.log` under
   my device dir; upload any media blobs referenced that the store lacks
   (existence check is the same one backup uses); then update `head`.
   Write-then-head means a torn upload is invisible to readers.
2. **Pull:** list peers' dirs; for each, read logs with seq > my cursor,
   decrypt, apply ops through the merge rule inside one transaction,
   advance cursor. Fetch referenced blobs lazily or eagerly per network
   policy (D-016 applies: bulk media over Wi-Fi unless allowed).
3. Triggers: on app open, on foreground, after a capture burst, manual.
   Same opportunistic pattern as the auto-backup runner; never blocks a
   save (hard rule 1 untouched — sync is an enhancement layer).

Bootstrap for a new member = pull everything (mechanically the restore
path: it already knows how to read a whole store and integrity-check it),
then go incremental.

Compaction (later, owner-only): fold logs older than N months into a
snapshot generation; not needed until logs are embarrassing.

## Carrier: Google Drive specifics

**The appdata folder cannot be shared** — it is private per-user by
design. So the shared store lives in a **regular Drive folder**, and the
app adds the `drive.file` scope: access *only* to files and folders the
app created or the user explicitly picked. `drive.file` is, like
`drive.appdata`, classed **non-sensitive** — no verification cliff, no
change to our production status; the consent screen gains one
plainly-worded line. The private appdata backup (D-021) is untouched and
remains the default backup home.

- **Owner:** "Share this property" → app creates `Field Notes — <property>`
  folder in their Drive, seeds it with the store, and opens **Drive's own
  sharing sheet** for it.
- **Contributor:** accepts the emailed Drive share like any folder, then in
  the app: "Join a shared property" → picks the folder (Drive UI picker,
  which is exactly what `drive.file` is for) → enters the passphrase →
  bootstrap pull.

### Roles are Drive ACLs — we do not build auth

| Role | How it's granted | What enforces it |
|---|---|---|
| Owner | owns the Drive folder | Drive |
| Contributor | folder shared as *editor* | Drive (can write own sync dir) |
| Viewer | folder shared as *viewer* | Drive (can pull, physically cannot push) |

This is the design's best trade: membership UI, removal, and even
read-only enforcement are Google's problem, at the transport layer, with
the owner managing people in an interface they already know. The app's
`members.json` is only a display-name registry so "created by" renders as
"Wylder" instead of a device id. One owner, N contributors, exactly as
asked; nothing finer until a real user needs it.

**LAN/directory carrier parity:** same layout, same code path through
`BackupTarget`. A family that hates Google can share over the LAN receiver
or a Syncthing folder; roles there collapse to "has the folder + key or
not", which is honest for that trust model.

## Crypto & revocation, stated plainly

- Same keyring-v1: one data key, wrapped by passphrase + recovery phrase.
  The owner hands the passphrase to members person-to-person (v1). Every
  log and blob in the shared folder is ciphertext; Google hosts the store
  and can read none of it — same claim, same mechanism, as backups today.
- **Removing someone:** un-sharing the folder cuts their access to
  everything they haven't already copied — that part is real and instant.
  What crypto cannot do is un-know a passphrase: after a removal that
  matters, the owner rotates (new data key, re-wrapped; blobs re-keyed
  lazily, logs from rotation forward). v1 ships un-share + "rotate key"
  as a deliberate, documented owner action, not an automatic dance.
- Per-member wrapped keys (no shared passphrase) is the v2 upgrade path;
  `members.json` reserves the slot.

## UI: the two-folder truth, said plainly (Austin, 2026-09-01)

The appdata/shared split must be visible in the UI, not discovered.
Settings consolidates into one **Data** section (this also settles audit
U4's "backup lives in three homes"):

```
DATA
  Backup            private · encrypted · only this account can see it
    → this phone · Google Drive (hidden app folder) · a computer (LAN)
  Shared property   a Drive folder you share · everyone in it syncs
    → share this property… / join a shared property…
```

Wording rule: **Backup** is *yours alone* (appdata, invisible in Drive);
**Sharing** is *a normal folder in your Drive* that shows up like any
folder and is shared like any folder. Never present sharing as "backup to
a shared place" — the trust models differ and the copy must not blur them.

## Owner review: "proposed edits" (Austin, 2026-09-01)

The ask: contributor changes surface in the owner's app as proposals, so
the lead steward always has final say. The oplog gives us two honest ways
to deliver that, and they differ in what *other* contributors see:

**Review-after (ships first).** Everyone's ops apply everywhere
immediately; the owner gets a **review feed** — every contributor op,
newest first, with one-tap **revert** (which emits a countermanding op that
wins by HLC). Final say is real: the owner can undo anything, with
attribution and history. Consistency is trivial because there is only ever
one applied state. This is the family-ranch default.

**Review-before (the gate, layered on later).** Contributor ops are
quarantined: devices apply owner ops always, their *own* ops immediately
(offline-first demands optimism about yourself), and other contributors'
ops **only once an owner approval op lists them**. Rejection emits a
rejection op; the author's device rolls its optimistic change back and
tells them why. This is real machinery — approval ops, a pending state,
divergence-until-approved — and it is what "proposed edit" strictly means.

**Design decision: a per-property switch, defaulting to review-after.**
"Edits apply right away, and I can undo anyone's" covers the trusted-family
case with a tenth of the moving parts; "edits wait for my OK" is the
contractor/volunteer case and justifies the extra state machine when a real
property needs it. Both modes are the same log format — the gate only
changes *when* an op is applied, so shipping review-after first forecloses
nothing. The desktop shell's Review workspace is the natural home for the
owner's feed either way.

## What deliberately does not sync

Prefs, API keys, the key cache, skin choice, map downloads, and
`env_contexts` *fetch state* (rows sync; whether a device looks context up
stays that device's D-022 switch). Local always works: a device that never
syncs again keeps a complete, exportable property.

## Failure modes, named

- **Clock skew:** HLC absorbs it; a device an hour slow still self-orders,
  ties break deterministically.
- **Torn upload:** logs are content-complete files; `head` moves last;
  readers ignore anything past `head`.
- **Schema drift:** ops carry `v` + app schema version; an older app
  refuses newer ops with "update Field Notes to sync with this property"
  rather than corrupting.
- **Two devices, one human:** works identically; a solo owner with phone +
  desktop is in fact the first user of this whole design (and the test
  rig: fake-Drive harness already exists from the restore drill).
- **Quota/size:** logs are text-tiny; media dominates and is already
  deduplicated by content hash.

## Build plan

- **M4a — the log, locally (no Drive):** op capture on every write,
  apply/merge engine, two-directory sync on a plain `DirectoryTarget`,
  torn-write and clock-skew tests. The hard 60%, fully host-testable.
- **M4b — Drive carrier + join flow:** `drive.file` scope, create/share
  folder, picker join, bootstrap-from-store, UNDO→tombstone change,
  attribution UI ("Wylder · 2 h ago").
- **M4c — polish:** LAN parity pass, key rotation action, sync status
  surface (last pushed/pulled per member), members display registry.

Phone + desktop as the two devices makes M4a/M4b shippable and testable
before a second human ever joins — which is also the correct excuse to
finish the desktop build first.
