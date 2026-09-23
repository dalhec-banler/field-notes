import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/ids.dart';
import 'package:field_notes/db/seed.dart';
import 'package:field_notes/geo/zone_assignment.dart';
import 'package:field_notes/import/kml_import.dart';
import 'package:field_notes/services/review.dart';
import 'package:flutter_test/flutter_test.dart';

/// Not a test of the app — a fixture generator for the desk (D-024). Builds
/// a realistic property database from the real Shorts Resort KML and writes
/// it where FN_FIXTURE_OUT points, so a desktop build can be staged with a
/// copy exactly the way a phone's backup would arrive. Skipped unless both
/// defines are set:
///
///   flutter test test/tools/desk_fixture_test.dart \
///     --dart-define=FN_FIXTURE_OUT=/path/db.sqlite \
///     --dart-define=FN_KML=/path/property.kml
void main() {
  const out = String.fromEnvironment('FN_FIXTURE_OUT');
  const kmlPath = String.fromEnvironment('FN_KML');

  test('build desk fixture', () async {
    if (out.isEmpty || kmlPath.isEmpty) {
      markTestSkipped('FN_FIXTURE_OUT / FN_KML not set');
      return;
    }
    final file = File(out);
    if (file.existsSync()) file.deleteSync();
    final db = FieldNotesDb.fromFile(file);
    await seedTaxaIfEmpty(
      db,
      csvText: File('assets/seed/states/TX.csv').readAsStringSync(),
    );
    await seedFeatureTypesIfEmpty(db);
    final now = nowUtcIso();

    final propId = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Shorts Resort',
            county: const Value('Lampasas'),
            state: const Value('TX'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );

    // Boundary + zones from the real KML, the way the import screen commits.
    final placemarks = parseKml(File(kmlPath).readAsStringSync());
    final zoneCentroids = <String, (double, double)>{};
    for (final pm in placemarks) {
      if (pm.geometryType != 'Polygon') continue;
      final geo = jsonDecode(pm.geojson) as Map<String, dynamic>;
      final ring = (geo['coordinates'] as List).first as List;
      var sx = 0.0, sy = 0.0;
      for (final c in ring) {
        sx += (c[0] as num).toDouble();
        sy += (c[1] as num).toDouble();
      }
      final centroid = (sy / ring.length, sx / ring.length);
      if (pm.name.contains('Shorts Resort')) {
        await (db.update(
          db.properties,
        )..where((p) => p.id.equals(propId))).write(
          PropertiesCompanion(
            boundaryGeojson: Value(pm.geojson),
            centroidLat: Value(centroid.$1),
            centroidLng: Value(centroid.$2),
          ),
        );
        continue;
      }
      final zid = newId();
      await db
          .into(db.zones)
          .insert(
            ZonesCompanion.insert(
              id: zid,
              propertyId: propId,
              name: pm.name,
              geojson: pm.geojson,
              notes: Value(pm.description),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
      zoneCentroids[zid] = centroid;
    }
    expect(zoneCentroids.length, greaterThanOrEqualTo(5));

    Future<String?> taxon(String prefix) async {
      final t =
          await (db.select(db.taxa)
                ..where((t) => t.scientificName.like('$prefix%'))
                ..limit(1))
              .getSingleOrNull();
      return t?.id;
    }

    final species = [
      (await taxon('Quercus'), 'certain', 'Live oak motte holding well.'),
      (
        await taxon('Juniperus'),
        'certain',
        'Cedar encroachment, cut this winter.',
      ),
      (await taxon('Prosopis'), 'probable', 'Mesquite resprout in the basin.'),
      (await taxon('Salix'), 'probable', 'Willow cuttings leafing out.'),
      (await taxon('Platanus'), 'certain', 'Sycamore seedlings on the bar.'),
      (
        await taxon('Schizachyrium'),
        'uncertain',
        'Little bluestem? Seed heads forming.',
      ),
      (null, null, 'Unknown forb, pink, ~40 cm. Photo taken.'),
    ];

    final centroids = zoneCentroids.entries.toList();
    var i = 0;
    final obsIds = <String>[];
    for (var k = 0; k < 14; k++) {
      final z = centroids[k % centroids.length].value;
      final sp = species[k % species.length];
      final lat = z.$1 + (k % 3 - 1) * 0.0004;
      final lng = z.$2 + (k % 2 == 0 ? 1 : -1) * 0.0003;
      final id = newId();
      final day = DateTime.utc(2026, 8, 1 + k, 14 + (k % 5));
      final type = k == 5
          ? 'problem'
          : k == 9
          ? 'water'
          : sp.$1 == null
          ? 'plant'
          : 'plant';
      await db
          .into(db.observations)
          .insert(
            ObservationsCompanion.insert(
              id: id,
              propertyId: propId,
              observedAt: day.toIso8601String(),
              localTz: 'America/Chicago',
              lat: lat,
              lng: lng,
              gpsAccuracyM: const Value(4.2),
              observationType: Value(type),
              taxonId: Value(type == 'plant' ? sp.$1 : null),
              taxonConfidence: Value(
                type == 'plant'
                    ? (sp.$1 == null ? 'unidentified' : sp.$2)
                    : 'unidentified',
              ),
              notes: Value(
                type == 'problem'
                    ? 'Headcut advancing ~1 m since spring. Needs rock.'
                    : type == 'water'
                    ? 'Spring running clear after the rain.'
                    : sp.$3,
              ),
              createdBy: k % 4 == 3 ? 'wylder' : 'local',
              createdAt: day.toIso8601String(),
              updatedAt: day.toIso8601String(),
            ),
          );
      await assignZone(
        db,
        observationId: id,
        propertyId: propId,
        lat: lat,
        lng: lng,
      );
      obsIds.add(id);
      i++;
    }
    expect(i, 14);

    // A contributor's record awaiting the steward's ruling.
    final review = ReviewService(db);
    for (var k = 3; k < 14; k += 4) {
      await review.markPending(
        propertyId: propId,
        entityType: 'observation',
        entityId: obsIds[k],
        author: 'wylder',
      );
    }

    Future<String> featureType(String key) async => (await (db.select(
      db.featureTypes,
    )..where((t) => t.typeKey.equals(key))).getSingle()).id;
    final c0 = centroids.first.value;
    final c1 = centroids[1].value;
    await db
        .into(db.features)
        .insert(
          FeaturesCompanion.insert(
            id: newId(),
            propertyId: propId,
            featureTypeId: await featureType('spring'),
            name: const Value('Bluff spring'),
            geojson: jsonEncode({
              'type': 'Point',
              'coordinates': [c0.$2 + 0.0006, c0.$1 - 0.0002],
            }),
            lat: Value(c0.$1 - 0.0002),
            lng: Value(c0.$2 + 0.0006),
            currentCondition: const Value('good'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.features)
        .insert(
          FeaturesCompanion.insert(
            id: newId(),
            propertyId: propId,
            featureTypeId: await featureType('erosion_zone'),
            name: const Value('Basin headcut'),
            geojson: jsonEncode({
              'type': 'Point',
              'coordinates': [c1.$2 - 0.0004, c1.$1 + 0.0003],
            }),
            lat: Value(c1.$1 + 0.0003),
            lng: Value(c1.$2 - 0.0004),
            currentCondition: const Value('poor'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );

    // One walk through three zones.
    final line = [
      for (final e in centroids.take(3)) [e.value.$2, e.value.$1],
    ];
    await db
        .into(db.tracks)
        .insert(
          TracksCompanion.insert(
            id: newId(),
            propertyId: propId,
            startedAt: '2026-08-20T13:05:00Z',
            endedAt: const Value('2026-08-20T14:10:00Z'),
            distanceM: const Value(2180),
            purpose: const Value('survey'),
            geojson: Value(
              jsonEncode({'type': 'LineString', 'coordinates': line}),
            ),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );

    await db.close();
    expect(file.existsSync(), isTrue);
  });
}
