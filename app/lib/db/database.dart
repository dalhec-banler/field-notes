import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

export 'ids.dart';

part 'database.g.dart';

@DriftDatabase(include: {'schema.drift'})
class FieldNotesDb extends _$FieldNotesDb {
  FieldNotesDb() : super(_openConnection());

  /// In-memory database for tests.
  FieldNotesDb.forTesting() : super(NativeDatabase.memory());

  /// Opens an existing database file (restore/verification flows).
  FieldNotesDb.fromFile(File file) : super(NativeDatabase(file));

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 4) {
        // v4: 'infrastructure' joins the record types (Austin, 2026-09-01:
        // weather leaves the pickers — context is captured automatically —
        // but stays legal for old rows). SQLite can't loosen a CHECK, so
        // the table is rebuilt: FKs are still off during migration.
        await m.database.customStatement("""
          CREATE TABLE observations_v4 (
            id            TEXT PRIMARY KEY NOT NULL,
            property_id   TEXT NOT NULL REFERENCES properties(id),
            zone_id       TEXT REFERENCES zones(id),
            feature_id    TEXT REFERENCES features(id),
            observed_at   TEXT NOT NULL,
            local_tz      TEXT NOT NULL,
            lat           REAL NOT NULL,
            lng           REAL NOT NULL,
            gps_accuracy_m REAL,
            altitude_m    REAL,
            heading_deg   REAL,
            observation_type TEXT NOT NULL DEFAULT 'general' CHECK (observation_type IN
                           ('general','plant','wildlife','problem','water','soil',
                            'phenology','sign','weather','maintenance',
                            'infrastructure')),
            taxon_id      TEXT REFERENCES taxa(id),
            taxon_confidence TEXT CHECK (taxon_confidence IN
                           ('certain','probable','uncertain','unidentified')),
            count_estimate INTEGER,
            phenology     TEXT CHECK (phenology IN
                           ('vegetative','budding','flowering','fruiting','seeding',
                            'senescent','dormant','dead')),
            is_suggestion INTEGER NOT NULL DEFAULT 0,
            accepted_at   TEXT,
            accepted_by   TEXT,
            notes         TEXT,
            env_context_id TEXT REFERENCES env_contexts(id),
            created_by TEXT NOT NULL, created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL, deleted_at TEXT
          )""");
        await m.database.customStatement(
          'INSERT INTO observations_v4 SELECT * FROM observations',
        );
        await m.database.customStatement('DROP TABLE observations');
        await m.database.customStatement(
          'ALTER TABLE observations_v4 RENAME TO observations',
        );
        await m.database.customStatement(
          'CREATE INDEX idx_obs_prop_time ON observations(property_id, observed_at DESC)',
        );
        await m.database.customStatement(
          'CREATE INDEX idx_obs_bbox ON observations(property_id, lat, lng)',
        );
        await m.database.customStatement(
          'CREATE INDEX idx_obs_taxon ON observations(taxon_id)',
        );
      }
      if (from < 3) {
        // v3: suggestion runs are distinguishable (review finding 7).
        await m.database.customStatement(
          'ALTER TABLE identification_suggestions ADD COLUMN run_id TEXT',
        );
      }
      // v2: review_items — pending-visible owner review (SYNC-DESIGN).
      if (from < 2) {
        await m.createTable(reviewItems);
        await m.createIndex(idxReviewPending);
      }
      // v6: a photo point is a station — same spot, height, DIRECTION and
      // FOCAL LENGTH (Austin, 2026-09-04). The first two were stored; these
      // are the rest, and they let the map draw what the frame looks at.
      if (from < 6) {
        for (final col in const [
          'focal_length_mm REAL',
          'view_extent_m REAL',
        ]) {
          try {
            await m.database.customStatement(
              'ALTER TABLE photo_points ADD COLUMN $col',
            );
          } catch (_) {
            // Already there (a re-run): nothing to do.
          }
        }
      }
      // v5 LAST (it inserts 'infrastructure'-typed rows, which need the
      // v4 CHECK already in place): features fold into records (Austin,
      // 2026-09-04). Live features become observations — SAME id on every
      // device, so the sync merge is deterministic — their condition logs
      // copy to the new timeline, and the old rows soft-delete.
      if (from < 5) {
        await m.createTable(conditionLogs);
        await m.createIndex(idxConditionObs);
        await m.database.customStatement('''
          INSERT INTO condition_logs (id, property_id, observation_id,
            observed_at, condition, action_taken, notes,
            created_by, created_at, updated_at, deleted_at)
          SELECT id, property_id, feature_id, observed_at, condition,
            action_taken, notes, created_by, created_at, updated_at,
            deleted_at
          FROM feature_condition_logs''');
        await m.database.customStatement('''
          INSERT OR IGNORE INTO observations (id, property_id, zone_id,
            observed_at, local_tz, lat, lng, gps_accuracy_m,
            observation_type, notes, created_by, created_at, updated_at,
            deleted_at)
          SELECT f.id, f.property_id, f.zone_id, f.created_at, 'UTC',
            COALESCE(f.lat, 0), COALESCE(f.lng, 0),
            CASE WHEN f.lat IS NULL THEN -1 ELSE NULL END,
            CASE COALESCE(t.feature_class, 'natural')
              WHEN 'infrastructure' THEN 'infrastructure'
              WHEN 'problem' THEN 'problem'
              ELSE CASE
                WHEN lower(COALESCE(t.label, '')) LIKE '%spring%'
                  OR lower(COALESCE(t.label, '')) LIKE '%creek%'
                  OR lower(COALESCE(t.label, '')) LIKE '%pond%'
                  OR lower(COALESCE(t.label, '')) LIKE '%tank%'
                  OR lower(COALESCE(t.label, '')) LIKE '%well%'
                  THEN 'water'
                WHEN lower(COALESCE(t.label, '')) LIKE '%den%'
                  OR lower(COALESCE(t.label, '')) LIKE '%nest%'
                  OR lower(COALESCE(t.label, '')) LIKE '%burrow%'
                  THEN 'wildlife'
                ELSE 'general'
              END
            END,
            TRIM(COALESCE(t.label, 'Feature')
              || CASE WHEN f.name IS NOT NULL
                   THEN ': ' || f.name ELSE '' END
              || CASE WHEN f.notes IS NOT NULL
                   THEN char(10) || f.notes ELSE '' END),
            f.created_by, f.created_at, f.updated_at, f.deleted_at
          FROM features f
          LEFT JOIN feature_types t ON t.id = f.feature_type_id''');
        await m.database.customStatement('''
          UPDATE features SET
            deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
          WHERE deleted_at IS NULL''');
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'field_notes.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

/// ISO-8601 UTC timestamp per spec §4.1.
String nowUtcIso() => DateTime.now().toUtc().toIso8601String();

/// Wall-clock timezone name for the `local_tz` columns.
String localTzName() => DateTime.now().timeZoneName;
