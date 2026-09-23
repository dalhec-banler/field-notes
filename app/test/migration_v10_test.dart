import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

/// A v9 database — the observations CHECK without 'survey', no protocol
/// tables — opened by this build must come up at v10 with its records
/// intact and the new type accepted.
void main() {
  test('v9 → v10 keeps observations and admits survey records', () async {
    final dir = Directory.systemTemp.createTempSync('fn-mig-');
    final file = File('${dir.path}/db.sqlite');
    final raw = sql.sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE properties (
        id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, description TEXT,
        county TEXT, state TEXT, country TEXT DEFAULT 'US', acreage REAL,
        land_tenure TEXT NOT NULL DEFAULT 'owned',
        boundary_geojson TEXT, centroid_lat REAL, centroid_lng REAL,
        default_share_mode TEXT NOT NULL DEFAULT 'fuzzed',
        fuzz_radius_m INTEGER DEFAULT 500,
        created_by TEXT NOT NULL, created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL, deleted_at TEXT)''');
    // Stubs for every table the FKs point at; enforcement is on at open.
    for (final t in [
      'zones',
      'features',
      'taxa',
      'env_contexts',
      'photo_points',
      'tracks',
    ]) {
      raw.execute('CREATE TABLE $t (id TEXT PRIMARY KEY NOT NULL)');
    }
    raw.execute('''
      CREATE TABLE observations (
        id TEXT PRIMARY KEY NOT NULL,
        property_id TEXT NOT NULL REFERENCES properties(id),
        zone_id TEXT, feature_id TEXT,
        observed_at TEXT NOT NULL, local_tz TEXT NOT NULL,
        lat REAL NOT NULL, lng REAL NOT NULL,
        gps_accuracy_m REAL, altitude_m REAL, heading_deg REAL,
        observation_type TEXT NOT NULL DEFAULT 'general' CHECK (observation_type IN
          ('general','plant','wildlife','problem','water','soil','phenology',
           'sign','weather','maintenance','infrastructure')),
        taxon_id TEXT, taxon_confidence TEXT, count_estimate INTEGER,
        phenology TEXT, is_suggestion INTEGER NOT NULL DEFAULT 0,
        accepted_at TEXT, accepted_by TEXT, notes TEXT, env_context_id TEXT,
        removal_status TEXT, removed_on TEXT,
        created_by TEXT NOT NULL, created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL, deleted_at TEXT)''');
    raw.execute(
      'CREATE INDEX idx_obs_prop_time ON observations(property_id, observed_at DESC)',
    );
    raw.execute(
      'CREATE INDEX idx_obs_bbox ON observations(property_id, lat, lng)',
    );
    raw.execute('CREATE INDEX idx_obs_taxon ON observations(taxon_id)');
    raw.execute(
      "INSERT INTO properties VALUES ('p1','Old place',NULL,NULL,NULL,'US',NULL,'owned',NULL,NULL,NULL,'fuzzed',500,'local','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',NULL)",
    );
    raw.execute(
      "INSERT INTO observations (id, property_id, observed_at, local_tz, lat, lng, observation_type, notes, removal_status, created_by, created_at, updated_at) VALUES ('o1','p1','2026-01-02T00:00:00Z','CST',31.06,-98.05,'plant','an old record','flagged','local','2026-01-02T00:00:00Z','2026-01-02T00:00:00Z')",
    );
    raw.execute('PRAGMA user_version = 9');
    raw.close();

    final db = FieldNotesDb.fromFile(file);
    addTearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    final kept = await (db.select(
      db.observations,
    )..where((o) => o.id.equals('o1'))).getSingle();
    expect(kept.notes, 'an old record');
    expect(kept.removalStatus, 'flagged');

    final now = nowUtcIso();
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: 'o2',
            propertyId: 'p1',
            observedAt: now,
            localTz: 'CST',
            lat: 31.06,
            lng: -98.05,
            observationType: const Value('survey'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    expect(await db.select(db.protocols).get(), isEmpty);
    expect(await db.select(db.protocolSites).get(), isEmpty);
    // Track the schema version rather than a literal, so adding a migration
    // doesn't fail this test for the wrong reason.
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data['user_version'], db.schemaVersion);
  });
}
