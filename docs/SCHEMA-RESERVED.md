# Reserved tables

Six tables in `app/lib/db/schema.drift` exist and are written by nothing.
They were created ahead of features that did not ship, and on every
database we have looked at (the desk baseline of 2026-10-13 under
`~/FieldNotes-backups/`) each holds zero rows.

D-038 item 9 takes them out of the code paths **without dropping them**. A
`DROP TABLE` is a migration, and the point of the hardening pass is no
schema bump. They are dropped at the next migration that rebuilds anyway;
until then they are listed in `app/lib/db/retired_tables.dart`
(`kRetiredTables`) and that one constant keeps them out of:

- the oplog — no capture triggers are installed on them, and a pulled op
  that names one (from an older peer, say) is skipped and counted, not
  applied and not an error (`OpLog.syncedTables`);
- the export — no `data/<name>.csv`, and `database.sqlite` hands them over
  empty, the same way it treats the `sync_*` bookkeeping
  (`Exporter.keepsInDatabase`);
- the taxa dedupe — `detections.taxon_id` is no longer swept when two
  library rows fold into one.

`test/retired_tables_test.dart` holds this in place.

| Table | Spec | Why it exists | Rows seen |
|---|---|---|---|
| `profiles` | §4.2 | Multi-user identity: a person with a display name and an avatar. Sharing shipped as device pairing (D-025, D-028) and a Drive folder per property (D-030) instead; a device has an id, not a profile. | 0 |
| `memberships` | §4.2 | A profile's role on a property (steward, ranger, scout, naturalist, guest). Roles were never built; D-030's "two seats free" is enforced at the carrier, not in a table. | 0 |
| `invites` | §4.2 | Tokened invitation links with expiry and use counts. An invitation today is a shared folder (D-030/D-031), not a token row. | 0 |
| `devices` | §4.12 | A trail camera, bioacoustic recorder, weather station or soil sensor registered to a property. Phase 2 of the spec; never started. Not to be confused with the sync notion of a device (`sync_meta.device_id`), which is this installation. | 0 |
| `deployments` | §4.12 | Where and when a `devices` row was put out, with bearing and height. Depends on `devices`. | 0 |
| `detections` | §4.12 | A model's call (BirdNET-Go, SpeciesNet) from a deployment, with confidence and a verification state. Depends on `deployments`. | 0 |

When they go, three `CHECK (… IN (…))` constraints go with them
(`memberships.role`, `devices.device_type`, `detections.verification`), and
the count pinned in `test/schema_check_enums_test.dart` comes down from 37
to 34.

## Rules while they are reserved

- Do not write to them. Nothing reads them, so a row written here is a row
  nobody will ever see again.
- Do not add them back to the exporter or the oplog "for completeness".
  Completeness is the reason they are out: an export is complete when it
  holds every table that holds user data, and these hold none.
- If a future feature wants one of these shapes, build it as a new table or
  rebuild this one in a migration. Do not reuse the reserved table as-is:
  it carries the CHECK enums D-038 forbids.
