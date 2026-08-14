import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/geo/zone_assignment.dart';
import 'package:flutter_test/flutter_test.dart';

String polygon(List<List<double>> ring) => jsonEncode({
      'type': 'Polygon',
      'coordinates': [ring],
    });

void main() {
  late FieldNotesDb db;
  late String propId;

  Future<String> addZone(String name, List<List<double>> ring,
      {String? parent}) async {
    final id = newId();
    final now = nowUtcIso();
    await db.into(db.zones).insert(ZonesCompanion.insert(
          id: id,
          propertyId: propId,
          name: name,
          geojson: polygon(ring),
          parentZoneId: Value(parent),
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
        ));
    return id;
  }

  setUp(() async {
    db = FieldNotesDb.forTesting();
    propId = newId();
    final now = nowUtcIso();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: propId,
          name: 'Test property',
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
        ));
  });

  tearDown(() => db.close());

  test('assigns the containing zone', () async {
    final z = await addZone('Section 1', [
      [-98.20, 31.00],
      [-98.10, 31.00],
      [-98.10, 31.10],
      [-98.20, 31.10],
      [-98.20, 31.00],
    ]);
    final got = await ZoneAssigner(db)
        .zoneIdFor(propertyId: propId, lat: 31.05, lng: -98.15);
    expect(got, z);
  });

  test('returns null outside all zones', () async {
    await addZone('Section 1', [
      [-98.20, 31.00],
      [-98.10, 31.00],
      [-98.10, 31.10],
      [-98.20, 31.10],
      [-98.20, 31.00],
    ]);
    final got = await ZoneAssigner(db)
        .zoneIdFor(propertyId: propId, lat: 32.0, lng: -98.15);
    expect(got, isNull);
  });

  test('nested zones: deepest match wins', () async {
    final outer = await addZone('Section 4', [
      [-98.20, 31.00],
      [-98.10, 31.00],
      [-98.10, 31.10],
      [-98.20, 31.10],
      [-98.20, 31.00],
    ]);
    final inner = await addZone(
        'Wetland pocket',
        [
          [-98.16, 31.04],
          [-98.14, 31.04],
          [-98.14, 31.06],
          [-98.16, 31.06],
          [-98.16, 31.04],
        ],
        parent: outer);
    final got = await ZoneAssigner(db)
        .zoneIdFor(propertyId: propId, lat: 31.05, lng: -98.15);
    expect(got, inner);
  });

  test('malformed geometry is skipped, never throws', () async {
    final now = nowUtcIso();
    await db.into(db.zones).insert(ZonesCompanion.insert(
          id: newId(),
          propertyId: propId,
          name: 'Broken',
          geojson: '{"type":"Garbage"}',
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
        ));
    final got = await ZoneAssigner(db)
        .zoneIdFor(propertyId: propId, lat: 31.05, lng: -98.15);
    expect(got, isNull);
  });

  test('assignZone writes the zone onto the observation', () async {
    final z = await addZone('Section 1', [
      [-98.20, 31.00],
      [-98.10, 31.00],
      [-98.10, 31.10],
      [-98.20, 31.10],
      [-98.20, 31.00],
    ]);
    final now = nowUtcIso();
    final obsId = newId();
    await db.into(db.observations).insert(ObservationsCompanion.insert(
          id: obsId,
          propertyId: propId,
          observedAt: now,
          localTz: 'CDT',
          lat: 31.05,
          lng: -98.15,
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
        ));
    final assigned = await assignZone(db,
        observationId: obsId, propertyId: propId, lat: 31.05, lng: -98.15);
    expect(assigned, z);
    final obs = await (db.select(db.observations)
          ..where((o) => o.id.equals(obsId)))
        .getSingle();
    expect(obs.zoneId, z);
  });
}
