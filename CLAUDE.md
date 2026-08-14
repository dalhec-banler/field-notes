# Field Notes

Local-first field journal for people who own and manage land. Flutter (Dart),
Android APK sideload first, desktop second. Full build spec lives in
`docs/SPEC.md` — read it before touching the data model. Decisions and approved
spec deviations are logged in `DECISIONS.md`; do not silently re-litigate either.

## Layout

- `docs/SPEC.md` — the build spec. §4 (data model) is the contract.
- `DECISIONS.md` — decision log; the only place spec deviations are recorded.
- `app/` — the Flutter project (`field_notes`).

## Hard rules (from the spec — do not violate)

1. Offline is the default state. Every read/write hits local SQLite; network is
   an enhancement. Never block a save on network, GPS lock, or species ID.
2. Data is portable: full export in open formats, no vendor dependency.
3. Coordinates of private land are sensitive. Nothing leaves the device without
   explicit user action; no telemetry containing coordinates.
4. Design for the return visit (continuity over volume).
5. §4 conventions: UUIDv7 TEXT primary keys, ISO-8601 UTC timestamps + `local_tz`,
   GeoJSON TEXT + denormalized lat/lng, TEXT CHECK enums, soft delete via
   `deleted_at`. No autoincrement ids, no SpatiaLite.
6. Survival rate is always derived, never stored.
7. Machine species IDs are never written to `observations.taxon_id` without user
   acceptance; every suggestion is retained in `identification_suggestions`.

## Stack

Flutter + drift over SQLite (PowerSync added at Milestone 4 — sync is optional;
the no-account path is built and tested first). Maps: `maplibre_gl` + PMTiles via
a local `shelf` HTTP server with Range support (MBTiles fallback if the timeboxed
prototype fails). Backend, when it arrives: Supabase behind PowerSync.

## Build order

Spec §8: M1 local core → M2 plantings/propagation → M3 features/photo
points/tracks → M3.5 encrypted backup → M4 sync/sharing → M5 intelligence →
M6 programs/devices. Each milestone has acceptance criteria in the spec — meet
them before moving on.
