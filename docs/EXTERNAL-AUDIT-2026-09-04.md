# External audit - Field Notes

Reviewed commit: `081be17964bd1e31a35a62fa9555c62b22971566`.
Scope: `EXTERNAL-AUDIT-BRIEF.md`, with `CLAUDE.md`, SPEC section 4,
`DECISIONS.md`, the design audit, and `SYNC-DESIGN.md` as constraints.
Production code was not changed.

**14 findings, supported by 15 failing reproductions.** The existing suite
passed: **143 passed, 2 skipped**. The separate audit suite finished with
**5 controls passed, 15 reproductions failed**. Its failures assert the
required behavior; they are not proposed fixes.

Sync exposure is qualified throughout: `main.dart:58` installs capture,
but production has no call to `OpLog.push` or `OpLog.pull`. The five sync
findings are blockers before enabling exchange, not claims that today's
app already uploads these batches.

## Findings

### 1. [P1] Interrupted migrations leave a database that cannot retry

**Location:** `app/lib/db/database.dart:28`, `:69`, `:118`.

Upgrade statements are not wrapped in a transaction. The installed native
Drift executor does not provide an implicit migration transaction. A v4
upgrade interrupted at the final feature update leaves `condition_logs`,
its index, copied observations, and v6 columns committed, with
`user_version` still 4. Reopening fails with **index idx_condition_obs
already exists**, even after the cause of the interruption is removed.
The v4 rebuild also has a crash window between dropping `observations`
and renaming its replacement.

**Reproduction:** `M1` injects a SQLite abort at the final feature update,
removes the fault, and attempts to reopen. The retry fails.

**Correction:** make the upgrade atomic, verify foreign keys before
committing, and provide recovery for databases already partially upgraded.
The broad exception handler on v6 column creation must not treat unrelated
database failures as evidence that the columns already exist.

### 2. [P1] A single-property export includes every other property's database rows

**Location:** `app/lib/export/exporter.dart:38`, `:55`.

Select a public collection site and share its export. CSVs and GeoJSON are
filtered to that site, but `database.sqlite` is an unrestricted `VACUUM
INTO` of the entire journal. The recipient also receives private-home
properties, coordinates, notes, deleted rows, and captured sync history.
The property-named archive and README describe an export of that place.

**Reproduction:** `P1` creates a public site and a private home, exports the
public site, and finds the private-home row in the resulting SQLite file.

**Correction:** apply the selected-property boundary to every artifact,
including referenced rows and sync bookkeeping. An all-property archive
needs its own explicit scope at the point of sharing.

### 3. [P1] Encrypted restore accepts another photo's valid ciphertext

**Location:** `app/lib/backup/backup_engine.dart:205`, `:206`.

Given two blobs encrypted under the same data key, replace blob A's stored
bytes with blob B's ciphertext. No key is needed to perform this substitution.
Both AEAD tags remain valid. Restore decrypts B and writes its bytes under
A's expected SHA-256 filename without checking that hash. The full staging
pipeline reports **Restored DB ... and 2 photos. Restart the app to finish.**
It has silently attached the wrong evidence to A's record.

**Reproduction:** `B1` performs the ciphertext replacement and calls
`RestorePipeline.stageFromTarget` with the correct passphrase; staging succeeds.

**Correction:** verify every restored blob against the authenticated
manifest's digest before accepting it. Bind database snapshots to the
manifest as well; SQLite integrity alone does not establish that a valid
database is the intended generation.

### 4. [P1] Missing backup media is silently accepted as a completed restore

**Location:** `app/lib/backup/backup_engine.dart:204`;
`app/lib/backup/restore.dart:251`, `:272`.

Delete the only photo blob from an otherwise valid encrypted backup.
Restore skips it, sets READY, and reports **Restored DB ... and 0 photos**
without identifying the missing expected photo. Remapping also skips absent
files without counting a failure and can delete the staging directory.
There is no retained media retrieval task to finish later.

**Reproduction:** `B2` removes a blob named in the sealed inventory. The
pipeline stages successfully instead of refusing the incomplete backup.

**Correction:** report expected versus restored/missing media explicitly.
Require an explicit partial-restore choice or refuse staging; retain a
retryable inventory if a partial restore is accepted.

### 5. [P1] A condition permitted by the old schema blocks the v5 upgrade

**Location:** `app/lib/db/database.dart:119`;
`app/lib/db/schema.drift:614`.

The old `feature_condition_logs.condition` is unrestricted `TEXT NOT NULL`.
The new table permits only good/fair/poor/critical/unknown, but the migration
copies the old text verbatim. One legacy row with `condition='dry'` causes
a CHECK failure and prevents the database from opening. This is conditional
on legacy data outside today's picker values, such as data written by a
tool; it is nevertheless valid under the specified old schema.

**Reproduction:** `M2` builds the historical v4 schema, inserts `dry`, and
opens it through the real current migration. The CHECK fails.

**Correction:** preserve legacy values, or explicitly map unsupported
conditions while retaining their original text. Combine this with finding 1
so a refused upgrade cannot leave a partially migrated database.

### 6. [P1] Backup inventories are read from a different state than their database dump

**Location:** `app/lib/backup/backup_engine.dart:64`, `:74`, `:78`.

Start a first backup with one live photo. While the database dump is being
uploaded, delete that photo in the app. The snapshot contains the live
media row, but the later query of the running database excludes it. The
committed manifest contains no blob for the snapshot's photo and can pass
verification because its inventory is empty. Serializing backup jobs does
not serialize ordinary journal writes.

**Reproduction:** `B3` makes the media deletion immediately after the
snapshot upload. The dump has one live photo; its inventory has zero.

**Correction:** derive the inventory from the same SQLite snapshot and
retain the referenced immutable files until the generation commits.

### 7. [P1, before sync activation] Restoring the phone onto the desk clones its device ID

**Location:** `app/lib/sync/oplog.dart:62`, `:67`, `:216`.

The device ID is stored inside `sync_meta` in the backed-up database.
Restore copies it, and startup adopts it. Phone and desk therefore use the
same sync directory, can write overlapping batch names/sequences, and skip
each other's batches as their own. This violates the single-writer-per-device
directory premise for the product's intended first two-device workflow.

**Reproduction:** `S1` backs up an installed phone log, restores its database,
and installs the desk log. Both IDs are `phone`.

**Correction:** keep installation identity outside portable journal data;
reconcile copied cursors and local sequence ownership during restore.

### 8. [P1, before sync activation] A delayed peer resurrects a hard-deleted row

**Location:** `app/lib/sync/oplog.dart:289`, `:306`.

A deletes a row and B receives the deletion. Applying it physically removes
the row and its conflict timestamp. C then uploads an edit made before
the deletion. B sees no local row and inserts C's stale payload, even though
its timestamp is older than the deletion B already applied.

**Reproduction:** `S3` performs this three-peer exchange; B's deleted row
returns with `old offline edit` as its name.

**Correction:** retain deletion versions/tombstones independently of whether
the domain row remains present. D-012's brief local UNDO does not authorize
discarding the version of a deletion already exchanged with peers.

### 9. [P1, before sync activation] Equal-timestamp merges compare the wrong device ID

**Location:** `app/lib/sync/oplog.dart:283`.

The tie-break compares the receiving device's ID with the incoming writer,
not the writer of the currently stored row. With IDs A < B < C and the same
timestamp, A first receives C's edit, then B's edit. A replaces C with B
because A < B. C keeps C, so replicas disagree after all cursors advance.

**Reproduction:** `S2` ends with B's value on A and C's value on C.

**Correction:** persist and compare the winning version's originating
device ID alongside its logical timestamp.

### 10. [P1, before sync activation] Raw timestamp ordering loses sequential edits

**Location:** `app/lib/sync/oplog.dart:85`, `:286`;
`app/lib/db/database.dart:182`.

After a 12:00 edit is exchanged, the originating device's clock is corrected
to 11:00 and it makes a new edit. The peer rejects the new edit while the
origin retains it, leaving permanent divergence. There is no hybrid logical
clock or persisted counter in the merge version.

Even with correct clocks, variable ISO precision is ordered incorrectly:
`12:00:00.000Z` compares greater than `12:00:00.000001Z` as text. Dart's
timestamp helper can produce both precision forms. The one-microsecond-later
edit is rejected.

**Reproductions:** `S4` and `S4b` demonstrate these two failures.

**Correction:** use a persisted, monotonic logical version with a canonical
comparison representation; the local op sequence alone is insufficient.

### 11. [P1, before sync activation] Sync bypasses backup encryption entirely

**Location:** `app/lib/sync/oplog.dart:192`, `:230`.

Calling `push(DirectoryTarget(...))` writes full row payloads as readable
JSON. Passing a Drive or LAN target does not change this: those targets
transport bytes, while encryption lives in `BackupEngine`, which OpLog
never calls. Any shared carrier would receive readable coordinates and
notes and could forge input batches. This is distinct from D-010's explicit
plain-backup choice; the sync API has no cipher or encryption choice.

**Reproduction:** `S5` finds the private property name verbatim in the batch.

**Correction:** authenticate and encrypt sync batches using the shared
keyring before connecting these methods to any carrier. Validate their
schema/version and sender identity before applying them.

### 12. [P2] Feature photos do not follow features into observations

**Location:** `app/lib/db/database.dart:127`, `:160`;
`app/lib/screens/record_detail_screen.dart:105`.

A feature with `media_links.entity_type='feature'` migrates to an observation
with the same ID, but its links retain the old entity type. The old feature
is soft-deleted, and record detail only looks for `entity_type='observation'`.
The migrated record therefore loses its visible photo attachments despite
the media still being present on disk.

**Reproduction:** `M3` migrates a feature with a photo link and finds zero
links under the new record identity.

**Correction:** migrate polymorphic references along with row identities.
Preserve the accepted feature-to-record design while retaining attachments.

### 13. [P2] Exported HTML executes markup supplied as a zone name

**Location:** `app/lib/export/map_html.dart:162`, `:201`.

A zone name containing `</script><script>globalThis.auditMarker = true</script>`
is emitted literally inside the DATA script. JSON encoding does not stop
the HTML parser from closing a script element. A malicious name from an
import can therefore execute code when the exported HTML is opened or
published. Popup handlers also concatenate names into `setHTML` without
escaping them.

**Reproduction:** `P2` confirms that the generated HTML contains the raw
script terminator and injected script. Browser execution was not part of
this host test.

**Correction:** use script-safe JSON serialization and construct popup text
with DOM text nodes or equivalent escaping.

### 14. [P2] Unlocated records are plotted as if their placeholder coordinates were real

**Location:** `app/lib/export/plate_subject_loader.dart:35`, `:69`.

An observation with `gps_accuracy_m=-1` and placeholder `(0,0)` becomes a
normal `PlateRecord`; its unlocated flag is discarded. The desktop map and
record-enabled plates/HTML plot it at `(0,0)`, or at a fabricated property
centroid for other capture paths. A migrated unlocated feature can also
expand the desk's fitted bounds far beyond the actual property. The full
GeoJSON export correctly handles the flag, so the outputs disagree.

**Reproduction:** `D1` inserts an explicitly unlocated observation and finds
it in the drawable record collection.

**Correction:** retain location validity through the subject model and
exclude unlocated records from point geometry and framing.

## Coverage and limits

- Historical schemas v2/v3/v4/v5 were read from their original commits, not
  approximated by changing `user_version` on a current database. All four
  ordinary upgrades and second opens passed; v2-v4 preserved the feature
  and condition IDs and passed `foreign_key_check`. The v4-before-v5
  infrastructure ordering is correct on these valid inputs.
- XChaCha20 calls delegate nonce creation to the installed cryptography
  implementation. No explicit reused nonce or raw backup-key write to app
  config/logs was found. Existing passphrase/recovery, tampering, secure
  secret inclusion/exclusion, and Drive mock tests passed. The substitution
  finding concerns object identity verification, not a broken AEAD primitive.
- Pl@ntNet receives the prepared send copies; re-encoding clears EXIF and
  the existing send-copy tests passed. The optional LLM also receives
  property/zone names and a location rounded to two decimal places.
- Environmental context defaults off and rounds before both HTTP requests;
  the existing zero-request and coarsening tests passed. USGS/Esri tile
  paths disclose XYZ viewport tiles; overlay and NAIP requests disclose a
  bounding box. Offline imagery capture uses USGS/NAIP, not the active Esri
  display source. These were source traces, not live device packet captures.
- There is one policy discrepancy requiring an explicit interpretation:
  imagery is intentionally default-on in `app_prefs.dart:86`, and the desk
  eagerly constructs its map and export workspace at startup
  (`desktop_shell.dart:365`, `export_workspace.dart:116`). This issues
  viewport requests without a separate networking opt-in. Sending a
  bounding box is still disclosure of an area. The strict wording of hard
  rule 3 and the intended automatic map behavior should be reconciled;
  this audit does not silently reinterpret that product choice.
- Plate record layers default off. Full-data export intentionally carries
  exact locations and attempts to write GPS into exported photo copies;
  it is not a redacted publishing export. Finding 2 concerns the additional,
  unselected properties it carries.
- Survival stays computed, with D-018's tagged denominator distinguished
  from cohort survival. Existing cohort/latest-check-in/tag tests passed.
  Acreage additionally passed an independent spherical-rectangle reference,
  hole subtraction, reversed winding, and MultiPolygon summation. Existing
  point-in-polygon and deepest-nesting tests passed. Antimeridian geometry,
  cyclic zone ancestry, and live multi-device survival workflows were not
  exercised; there is no blanket correctness claim for those inputs.
- No real backup store, user journal database, credentials, or external
  account was modified. Platform keystore behavior, power-loss durability,
  and live provider behavior require device-level verification beyond these
  host tests.

## Reproduction

From `app/`:

```sh
flutter test
flutter test tool/external_audit_test.dart --reporter expanded
flutter test tool/external_audit_test.dart --plain-name 'M1:'
```

The audit suite lives outside `test/`, so the default suite stays unchanged.
Its migration fixtures require this repository's git history. All databases,
backup blobs, and exported test files are synthetic and cleaned up after
each test. Test KDF parameters are deliberately small; production parameters
were not changed.

The immediate repair order is migrations, export scope, and backup integrity.
The five sync issues should be resolved together before activating exchange.
