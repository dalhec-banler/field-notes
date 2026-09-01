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
  int get schemaVersion => 4;

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
