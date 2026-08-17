import 'dart:convert';

import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/env_context.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late FieldNotesDb db;
  late String propId;
  var sdaCalls = 0;

  http.Client fakeClient({bool weatherFails = false}) {
    return MockClient((request) async {
      if (request.url.host.contains('open-meteo')) {
        if (weatherFails) return http.Response('oops', 500);
        // 30 days: dry except 5 days ago (12 mm).
        final precip = List<double>.filled(30, 0.0);
        precip[24] = 12.0;
        return http.Response(
            jsonEncode({
              'daily': {
                'temperature_2m_min': List<double>.filled(30, 21.0),
                'temperature_2m_max': List<double>.filled(30, 38.5),
                'precipitation_sum': precip,
              }
            }),
            200);
      }
      if (request.url.host.contains('SDMDataAccess') ||
          request.url.host.contains('sc.egov.usda.gov')) {
        sdaCalls++;
        return http.Response(
            jsonEncode({
              'Table': [
                ['398492', 'Krum', 'fine', 'Moderately well drained']
              ]
            }),
            200);
      }
      return http.Response('not found', 404);
    });
  }

  setUp(() async {
    db = FieldNotesDb.forTesting();
    sdaCalls = 0;
    final now = nowUtcIso();
    propId = newId();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: propId,
          name: 'SFS',
          createdBy: 'a',
          createdAt: now,
          updatedAt: now,
        ));
  });

  tearDown(() => db.close());

  test('createStale never needs the network', () async {
    final service = EnvContextService(db, client: fakeClient());
    final id = await service.createStale(
        propertyId: propId, lat: 31.05, lng: -98.18, resolvedFor: '2026-08-01');
    final row = await (db.select(db.envContexts)
          ..where((e) => e.id.equals(id)))
        .getSingle();
    expect(row.isStale, 1);
    expect(row.precip30dMm, isNull);
  });

  test('backfill fills weather + soil and clears stale flag', () async {
    final service = EnvContextService(db,
        client: fakeClient(), courtesyDelay: Duration.zero);
    final id = await service.createStale(
        propertyId: propId, lat: 31.05, lng: -98.18, resolvedFor: '2026-08-01');
    final done = await service.backfillStale();
    expect(done, 1);

    final row = await (db.select(db.envContexts)
          ..where((e) => e.id.equals(id)))
        .getSingle();
    expect(row.isStale, 0);
    expect(row.tempMaxC, 38.5);
    expect(row.precip30dMm, 12.0);
    expect(row.precip7dMm, 12.0); // rain 5 days ago is inside the week
    expect(row.precip24hMm, 0.0);
    expect(row.daysSinceRain, 5);
    expect(row.soilSeries, 'Krum');
    expect(row.soilDrainageClass, 'Moderately well drained');
  });

  test('soil lookups are cached for nearby points (SDA throttling)', () async {
    final service = EnvContextService(db,
        client: fakeClient(), courtesyDelay: Duration.zero);
    for (var i = 0; i < 3; i++) {
      await service.createStale(
          propertyId: propId,
          lat: 31.0501, // all within the rounding cell
          lng: -98.1801,
          resolvedFor: '2026-08-0${i + 1}');
    }
    await service.backfillStale();
    expect(sdaCalls, 1);
  });

  test('a failing fetch leaves the row stale for a later retry', () async {
    final service = EnvContextService(db,
        client: fakeClient(weatherFails: true), courtesyDelay: Duration.zero);
    final id = await service.createStale(
        propertyId: propId, lat: 31.05, lng: -98.18, resolvedFor: '2026-08-01');
    final done = await service.backfillStale();
    expect(done, 0);
    final row = await (db.select(db.envContexts)
          ..where((e) => e.id.equals(id)))
        .getSingle();
    expect(row.isStale, 1);
  });
}
