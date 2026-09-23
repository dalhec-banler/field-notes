import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'seed_synonyms.dart';

export 'ids.dart';

part 'database.g.dart';

@DriftDatabase(include: {'schema.drift'})
class FieldNotesDb extends _$FieldNotesDb {
  FieldNotesDb() : super(_openConnection());

  /// In-memory database for tests.
  FieldNotesDb.forTesting() : super(NativeDatabase.memory());

  /// Opens an existing database file (restore/verification flows).
  FieldNotesDb.fromFile(File file) : super(NativeDatabase(file));

  /// Fires once on listen, then again whenever any of [tables] changes.
  ///
  /// drift hands the same live stream to every watcher whose SQL text and
  /// variables match, and `readsFrom` is not part of that match — so two
  /// `SELECT 1` watches on different tables quietly became one stream that
  /// followed only the first set registered. The map's pins stopped
  /// following record edits that way: the photo-point watch had claimed
  /// `SELECT 1` first (2026-09-08). Naming the tables in the text keys each
  /// watch by what it watches, so equal sets share and different sets
  /// never do.
  Stream<void> changes(Set<ResultSetImplementation> tables) {
    final names = tables.map((t) => t.entityName).toList()..sort();
    return customSelect(
      'SELECT 1 /* ${names.join(',')} */',
      readsFrom: tables,
    ).watch();
  }

  @override
  int get schemaVersion => 11;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async => m.createAll(),
    onUpgrade: (m, from, to) async {
      // ATOMIC (external audit 2026-09-04, finding 1): the native executor
      // gives migrations no implicit transaction, so an upgrade interrupted
      // partway left committed tables and indexes with user_version still
      // behind — and the retry then died on "index already exists". All or
      // nothing, or the database can't be reopened at all.
      await m.database.transaction(() async {
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
            } catch (e) {
              // Only "already there" is survivable; anything else is a real
              // failure and must abort the migration (audit finding 1).
              if (!'$e'.toLowerCase().contains('duplicate column')) rethrow;
            }
          }
        }
        // v7 (D-027): a record can be flagged for removal, and then marked
        // removed on a day — "removal is just as important a part of
        // restoration work as planting" (Austin, 2026-09-07). Plain
        // columns on upgrade; the CHECK lives in schema.drift for fresh
        // databases.
        if (from < 7) {
          for (final col in const ['removal_status TEXT', 'removed_on TEXT']) {
            try {
              await m.database.customStatement(
                'ALTER TABLE observations ADD COLUMN $col',
              );
            } catch (e) {
              if (!'$e'.toLowerCase().contains('duplicate column')) rethrow;
            }
          }
        }
        // v8 (D-029): a batch can say what "other" method it used, and a
        // mother plant can point at the record it was found as — the map
        // link from bench back to the ground.
        if (from < 8) {
          for (final (table, col) in const [
            ('propagation_batches', 'method_other TEXT'),
            (
              'source_plants',
              'observation_id TEXT REFERENCES observations(id)',
            ),
          ]) {
            try {
              await m.database.customStatement(
                'ALTER TABLE $table ADD COLUMN $col',
              );
            } catch (e) {
              if (!'$e'.toLowerCase().contains('duplicate column')) rethrow;
            }
          }
        }
        // v9 (D-032): a species carries its other scientific names, so an
        // identifier that answers with a current name finds the row the
        // library filed under an older one — Sophora → Dermatophyllum made
        // a duplicate (Austin, 2026-09-10). The seed list's synonyms are
        // applied to rows already here, in both directions.
        if (from < 9) {
          try {
            await m.database.customStatement(
              'ALTER TABLE taxa ADD COLUMN synonyms TEXT',
            );
          } catch (e) {
            if (!'$e'.toLowerCase().contains('duplicate column')) rethrow;
          }
          await applySeedSynonyms(this);
        }
        if (from < 10) {
          // v10 (D-033): monitoring protocols, and 'survey' joins the record
          // types. SQLite can't loosen a CHECK, so observations is rebuilt
          // the v4 way — FKs are off during migration — with every column
          // it has grown since (removal_status, removed_on).
          await m.database.customStatement("""
          CREATE TABLE observations_v10 (
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
                            'infrastructure','survey')),
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
            removal_status TEXT CHECK (removal_status IN ('flagged','removed')),
            removed_on    TEXT,
            created_by TEXT NOT NULL, created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL, deleted_at TEXT
          )""");
          await m.database.customStatement(
            'INSERT INTO observations_v10 (id, property_id, zone_id, '
            'feature_id, observed_at, local_tz, lat, lng, gps_accuracy_m, '
            'altitude_m, heading_deg, observation_type, taxon_id, '
            'taxon_confidence, count_estimate, phenology, is_suggestion, '
            'accepted_at, accepted_by, notes, env_context_id, '
            'removal_status, removed_on, created_by, created_at, '
            'updated_at, deleted_at) '
            'SELECT id, property_id, zone_id, feature_id, observed_at, '
            'local_tz, lat, lng, gps_accuracy_m, altitude_m, heading_deg, '
            'observation_type, taxon_id, taxon_confidence, count_estimate, '
            'phenology, is_suggestion, accepted_at, accepted_by, notes, '
            'env_context_id, removal_status, removed_on, created_by, '
            'created_at, updated_at, deleted_at FROM observations',
          );
          await m.database.customStatement('DROP TABLE observations');
          await m.database.customStatement(
            'ALTER TABLE observations_v10 RENAME TO observations',
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
          await m.createTable(protocols);
          await m.createIndex(idxProtocolsProp);
          await m.createTable(protocolSites);
          await m.createIndex(idxPsiteBbox);
          await m.createIndex(idxPsiteDue);
          await m.createTable(protocolRuns);
          await m.createIndex(idxPrunSiteTime);
          await m.createIndex(idxPrunObs);
        }

        // v11: imported maps become a thing you can take back out. Each zone
        // remembers the import it arrived in; removing that import removes
        // them together. Hand-drawn zones have a null import_id and are never
        // touched by it.
        if (from < 11) {
          await m.database.customStatement(
              'ALTER TABLE zones ADD COLUMN import_id TEXT');
          await m.createTable(mapImports);
          await m.createIndex(idxMapImportsProperty);
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
          SELECT id, property_id, feature_id, observed_at,
            CASE WHEN condition IN
                 ('good','fair','poor','critical','unknown')
              THEN condition ELSE 'unknown' END,
            action_taken,
            -- A legacy value the new CHECK won't take is preserved as
            -- text rather than failing the upgrade (audit finding 5).
            CASE WHEN condition IN
                 ('good','fair','poor','critical','unknown')
              THEN notes
              ELSE TRIM(COALESCE(notes || char(10), '')
                   || 'condition recorded as: ' || condition) END,
            created_by, created_at, updated_at, deleted_at
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
          // Attachments follow the identity: a feature's photos are the
          // record's photos now, or the migrated record looks empty while
          // its media sits on disk (audit finding 12).
          await m.database.customStatement('''
          UPDATE media_links SET entity_type = 'observation'
          WHERE entity_type = 'feature'
            AND entity_id IN (SELECT id FROM observations)''');
          await m.database.customStatement('''
          UPDATE media_links SET
            entity_type = 'observation',
            entity_id = (SELECT l.feature_id FROM feature_condition_logs l
                         WHERE l.id = media_links.entity_id)
          WHERE entity_type = 'feature_condition_log'
            AND (SELECT l.feature_id FROM feature_condition_logs l
                 WHERE l.id = media_links.entity_id) IN
                (SELECT id FROM observations)''');
          await m.database.customStatement('''
          UPDATE features SET
            deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
          WHERE deleted_at IS NULL''');
        }
      });
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
