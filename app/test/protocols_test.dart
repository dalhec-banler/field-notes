import 'dart:convert';

import 'package:field_notes/db/database.dart';
import 'package:field_notes/protocols/field_defs.dart';
import 'package:field_notes/protocols/indicators.dart';
import 'package:field_notes/protocols/protocol_service.dart';
import 'package:field_notes/protocols/templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('templates', () {
    test('every template round-trips its fields through JSON', () {
      for (final t in templates) {
        final parsed = parseFields(t.fieldsJson);
        expect(parsed.length, t.fields.length, reason: t.methodKey);
        expect(encodeFields(parsed), t.fieldsJson, reason: t.methodKey);
      }
    });

    test('four starters, three more, every class scale exists', () {
      expect(starterTemplates.map((t) => t.methodKey), [
        'cover_check',
        'brush_count',
        'cover_pole',
        'bird_listen',
      ]);
      expect(moreTemplates.length, 3);
      void check(List<FieldDef> fs) {
        for (final f in fs) {
          if (f.type == FieldType.class_) {
            expect(scales.containsKey(f.scale), isTrue, reason: f.key);
          }
          check(f.fields);
        }
      }

      for (final t in templates) {
        check(t.fields);
      }
    });
  });

  group('indicators', () {
    test('cover check averages Daubenmire midpoints, zero counts', () {
      final values = jsonEncode({
        'quadrat': [
          {'grass': '3', 'forb': '1', 'woody': '0', 'bare': '4'},
          {'grass': '5', 'forb': '1', 'woody': '0', 'bare': '2'},
        ],
      });
      final out = computeIndicators(
        methodKey: 'cover_check',
        valuesJson: values,
        siteKind: 'line',
        lengthM: 25,
      );
      final byKey = {for (final i in out) i.key: i};
      expect(byKey['pct_grass']!.value, closeTo((37.5 + 85) / 2, 0.01));
      expect(byKey['pct_woody']!.value, 0);
      expect(byKey['pct_bare']!.value, closeTo((62.5 + 15) / 2, 0.01));
      expect(byKey['pct_litter']!.value, isNull, reason: 'never answered');
    });

    test('brush count scales a 1/100-acre plot to stems per acre', () {
      final values = jsonEncode({
        'stems': [
          {'taxon_id': 'juniper', 'count': 7, 'by': 'seedling'},
          {'taxon_id': 'juniper', 'count': 2, 'by': 'shrub'},
          {'taxon_id': 'mesquite', 'count': 3, 'by': 'tree'},
        ],
      });
      final out = computeIndicators(
        methodKey: 'brush_count',
        valuesJson: values,
        siteKind: 'plot',
        radiusM: 3.59,
        nameOf: (id) => id.toUpperCase(),
      );
      final total = out.firstWhere((i) => i.key == 'stems_per_acre');
      // π·3.59² ≈ 40.49 m² ≈ 0.01 ac → 12 stems ≈ 1,200/ac.
      expect(total.value, closeTo(1200, 15));
      final by = out.firstWhere((i) => i.key == 'stems_per_acre_by_species');
      expect(by.detail, startsWith('JUNIPER: 9'));
    });

    test('cover pole reads the mean band and says what it means', () {
      final values = jsonEncode({
        'vor': [
          {'band_cm': 30},
          {'band_cm': 20},
          {'band_cm': 25},
          {'band_cm': 35},
        ],
      });
      final out = computeIndicators(
        methodKey: 'cover_pole',
        valuesJson: values,
        siteKind: 'point',
      );
      expect(out.first.value, 27.5);
      expect(out.last.detail, 'nesting cover');
    });

    test('pin walk: foliar, bare ground and gaps', () {
      final pins = [
        for (var i = 0; i < 10; i++)
          if (i < 6)
            {
              'top': ['grass'],
              'surface': 'basal',
            }
          else if (i < 9)
            {'top': <String>[], 'lower': <String>[], 'surface': 'S'}
          else
            {'top': <String>[], 'lower': <String>[], 'surface': 'L'},
      ];
      final values = jsonEncode({
        'point': pins,
        'gaps': [
          {'start_m': 2.0, 'end_m': 4.0},
          {'start_m': 10.0, 'end_m': 10.2},
        ],
      });
      final out = computeIndicators(
        methodKey: 'pin_walk',
        valuesJson: values,
        siteKind: 'line',
        lengthM: 25,
      );
      final byKey = {for (final i in out) i.key: i};
      expect(byKey['pct_foliar']!.value, 60);
      expect(byKey['pct_bare_ground']!.value, 30);
      expect(byKey['pct_litter']!.value, 10);
      expect(byKey['pct_gaps_over_50cm']!.value, closeTo(8, 0.01));
    });

    test('spotlight drive: acres sampled and the TPWD ratios', () {
      final values = jsonEncode({
        'bucks': 2,
        'does': 6,
        'fawns': 3,
        'unknown': 1,
        'visibility': [
          {'visibility_m': 100},
          {'visibility_m': 50},
        ],
      });
      final out = computeIndicators(
        methodKey: 'spotlight_drive',
        valuesJson: values,
        siteKind: 'route',
        lengthM: 5000,
      );
      final byKey = {for (final i in out) i.key: i};
      // 5000 m × 75 m × 2 sides = 750,000 m² ≈ 185.3 ac.
      expect(byKey['acres_sampled']!.value, closeTo(185.3, 0.1));
      expect(byKey['acres_per_deer']!.value, closeTo(15.4, 0.1));
      expect(byKey['does_per_buck']!.value, 3);
      expect(byKey['fawns_per_doe']!.value, 0.5);
    });
  });

  group('service', () {
    late FieldNotesDb db;
    late String propId;
    late ProtocolService svc;

    setUp(() async {
      db = FieldNotesDb.forTesting();
      svc = ProtocolService(db);
      propId = newId();
      final now = nowUtcIso();
      await db
          .into(db.properties)
          .insert(
            PropertiesCompanion.insert(
              id: propId,
              name: 'Test',
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    });

    tearDown(() => db.close());

    test('templates copy in once per property', () async {
      expect(await svc.ensureTemplates(propId), templates.length);
      expect(await svc.ensureTemplates(propId), 0);
      final ps = await svc.protocolsFor(propId);
      expect(ps.length, templates.length);
      expect(ps.first.isStarter, 1);
    });

    test('a site is due today, a complete run rolls it forward', () async {
      await svc.ensureTemplates(propId);
      final cover = (await svc.protocolsFor(propId))
          .firstWhere((p) => p.methodKey == 'cover_check');
      final site = await svc.createSite(
        protocol: cover,
        name: 'Wetland edge 1',
        lat: 31.06,
        lng: -98.05,
        bearingDeg: 90,
      );
      expect(site.lengthM, 25, reason: 'template default');
      expect(jsonDecode(site.geojson!)['type'], 'LineString');
      expect((await svc.dueSites(propId)).map((s) => s.id), [site.id]);

      final run = await svc.saveRun(
        protocol: cover,
        site: site,
        values: {
          'quadrat': [
            {'grass': '3', 'forb': '2', 'woody': '1', 'bare': '2'},
          ],
        },
        actualLat: 31.0601,
        actualLng: -98.0502,
        gpsAccuracyM: 4,
      );
      final obs = await (db.select(
        db.observations,
      )..where((o) => o.id.equals(run.observationId))).getSingle();
      expect(obs.observationType, 'survey');
      expect(obs.lat, 31.0601);
      expect(await svc.dueSites(propId), isEmpty, reason: 'rolled 365 days');
      final again = await (db.select(
        db.protocolSites,
      )..where((s) => s.id.equals(site.id))).getSingle();
      expect(again.nextDueOn, isNotNull);
      expect(again.nextDueOn!.compareTo(site.nextDueOn!), greaterThan(0));
      expect(await svc.runForObservation(obs.id), isNotNull);
    });

    test(
      'a partial run keeps the site due and sits on the site unlocated',
      () async {
        await svc.ensureTemplates(propId);
        final pole = (await svc.protocolsFor(propId))
            .firstWhere((p) => p.methodKey == 'cover_pole');
        final site = await svc.createSite(
          protocol: pole,
          name: 'Pole 1',
          lat: 31.06,
          lng: -98.05,
        );
        final run = await svc.saveRun(
          protocol: pole,
          site: site,
          values: {
            'vor': [
              {'band_cm': 30},
            ],
          },
          actualLat: null,
          actualLng: null,
          status: 'partial',
        );
        final obs = await (db.select(
          db.observations,
        )..where((o) => o.id.equals(run.observationId))).getSingle();
        expect(obs.gpsAccuracyM, -1);
        expect(obs.lat, site.lat);
        expect((await svc.dueSites(propId)).length, 1);
      },
    );

    test('missing required answers read as sentences, not asterisks', () {
      final fields = templateFor('cover_check')!.fields;
      final missing = ProtocolService.missingRequired(fields, {
        'quadrat': [
          {'grass': '3', 'forb': '2', 'woody': '1'},
        ],
      });
      expect(missing, [
        '4 of 5 frames still to do',
        'Needs bare dirt in frame 1',
      ]);
    });
  });
}
