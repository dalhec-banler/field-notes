# External audit brief — Field Notes

Hand this to an outside reviewer (a different model, or a person). It
exists because everything in this repo was written, reviewed, and
verified by the same author: the code review, the design audit, and the
simplification pass were all run by agents with the same priors. What is
wanted here is the thing that cannot come from inside — a reader who
does not share those assumptions.

## What this is

A local-first field journal for people who own and manage land. Flutter,
Android APK sideload first, macOS desk companion second. Offline is the
default state; the phone originates records and the desk reviews,
refines and publishes them.

- `CLAUDE.md` — the hard rules. **Treat these as constraints, not
  suggestions.**
- `docs/SPEC.md` — the build spec. §4 (data model) is the contract.
- `DECISIONS.md` — every decision and approved spec deviation, D-001
  onward. If something looks wrong, check here first: it may be a
  deliberate, argued choice.
- `docs/DESIGN-AUDIT-2026-09-03.md` — the most recent internal audit and
  what remains open from it.

## What would be most useful, in order

These are the seams where a bug is expensive and quiet.

1. **Migrations.** `app/lib/db/database.dart` — schema versions 2→6.
   v5 folds the `features` table into `observations` with same-id
   inserts and copies `feature_condition_logs` into `condition_logs`;
   v6 adds columns to `photo_points`. This rewrites real user data.
   Look for: rows silently dropped, CHECK-constraint violations on old
   data, ordering hazards between the v4 table rebuild and the v5
   inserts, re-run safety, and whether the same-id scheme is actually
   deterministic across two devices that migrate independently.
2. **Backup and keys.** `app/lib/backup/` — Argon2id + XChaCha20 AEAD,
   a random data key wrapped by both a passphrase and a BIP-39 recovery
   phrase, HMAC blob names, incremental manifests. Look for: nonce
   reuse, key material reaching disk or logs, the restore path trusting
   anything it should verify, and whether a tampered backup fails loudly.
3. **Sync.** `app/lib/sync/oplog.dart` + `docs/SYNC-DESIGN.md`. Capture
   by SQLite triggers, batches on a shared folder, row-level
   last-writer-wins with a device-id tiebreak. Look for: ops lost or
   double-applied, tombstone resurrection, clock-skew behaviour, and the
   guard that stops applied ops re-capturing as local ones.
4. **Privacy — hard rule 3.** Coordinates of private land must not leave
   the device without explicit user action. Trace every outbound path:
   Pl@ntNet identification (`app/lib/id/`), imagery tiles (Esri, USGS,
   NAIP), Open-Meteo and USDA-NRCS enrichment
   (`app/lib/services/env_context.dart`), Google Drive backup, and the
   exports in `app/lib/export/`. Known intended behaviour: identification
   send-copies are re-encoded with EXIF stripped, enrichment rounds the
   coordinate to ~1 km and is off by default, overlay/tile requests send
   only a bounding box, and record locations are off by default on
   exported plates. Verify that this is what the code actually does.
5. **Correctness of the derived numbers.** Survival is always derived,
   never stored (`app/lib/services/survival.dart`); acreage comes from
   spherical excess (`app/lib/export/plate_subject_loader.dart`);
   zone assignment is point-in-polygon with deepest-match nesting
   (`app/lib/geo/zone_assignment.dart`).

## How to report

- Findings with `file:line`, a one-line claim, a concrete failure
  scenario (inputs → wrong result), and a severity.
- Rank by consequence, not by count. Ten style nits are worth less than
  one migration that drops a row.
- `flutter test` runs 143 tests from `app/`. A finding that comes with a
  failing test is worth five that do not.

## Please don't

- Don't restyle. The visual system, the voice, and the press/quiet skins
  are decided (D-023 and the design README). Prose in the UI is
  deliberate.
- Don't relitigate what `DECISIONS.md` settles. If you disagree with a
  decision, say so once, briefly, and move on.
- Don't propose adding a backend, an account system, or telemetry. The
  no-account, offline-first path is the product.

## Known and deliberate, so you can skip them

- `sync_ops.seq` uses AUTOINCREMENT, against the §4 UUID convention.
  It is sync plumbing and never leaves the device as an identity.
- The desktop Google OAuth client id and secret are in source. Google
  classifies installed-app secrets as non-confidential; the loopback +
  PKCE flow does not rely on secrecy. (Still worth confirming the repo's
  visibility is what the owner intends.)
- The export plate uses its own renderer rather than the map library —
  maplibre_gl has no desktop platform.
- Esri imagery is display-only by its terms; only public-domain USGS and
  NAIP tiles are ever written to disk for offline use.
