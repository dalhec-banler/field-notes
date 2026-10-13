import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/seed.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression: the capture trigger's row_ts expression was
/// `COALESCE(<one column>)` on tables with a single timestamp column, and
/// SQLite refuses COALESCE with fewer than two arguments — at INSERT time,
/// not at CREATE TRIGGER time. feature_types (created_at only) could not
/// be written while the app was running, so a fresh install never seeded
/// its feature types. The startup order in main.dart is what this mirrors:
/// OpLog first, seed second.
void main() {
  test('a table with one timestamp column is still writable and captured',
      () async {
    final db = FieldNotesDb.forTesting();
    addTearDown(db.close);
    await OpLog.install(db, deviceId: 'device-a');

    final seeded = await seedFeatureTypesIfEmpty(db);
    expect(seeded, greaterThan(0));

    final ops = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM sync_ops WHERE table_name = 'feature_types'",
        )
        .getSingle();
    expect(ops.data['n'], seeded, reason: 'every seed row is journalled');
    final rowTs = await db
        .customSelect(
          "SELECT row_ts FROM sync_ops WHERE table_name = 'feature_types' LIMIT 1",
        )
        .getSingle();
    expect(rowTs.data['row_ts'], isNotEmpty);
  });

  test('track points (recorded_at only) land while recording', () async {
    final db = FieldNotesDb.forTesting();
    addTearDown(db.close);
    await OpLog.install(db, deviceId: 'device-a');
    final now = nowUtcIso();
    final propId = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Walk',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final trackId = newId();
    await db
        .into(db.tracks)
        .insert(
          TracksCompanion.insert(
            id: trackId,
            propertyId: propId,
            startedAt: now,
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    // What TrackRecorder writes for every fix.
    await db
        .into(db.trackPoints)
        .insert(
          TrackPointsCompanion.insert(
            id: newId(),
            trackId: trackId,
            recordedAt: now,
            lat: 30.88,
            lng: -98.54,
          ),
        );
    expect(await db.select(db.trackPoints).get(), hasLength(1));
    final ops = await db
        .customSelect(
          "SELECT row_ts FROM sync_ops WHERE table_name = 'track_points'",
        )
        .get();
    expect(ops, hasLength(1));
    expect(ops.single.data['row_ts'], now);
  });
}
