import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/id/range_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The third identification layer: how often a candidate has actually been
/// recorded near here. Evidence, not another opinion — and never a name.
void main() {
  late FieldNotesDb db;
  setUp(() => db = FieldNotesDb.forTesting());
  tearDown(() => db.close());

  final calls = <Uri>[];

  http.Client fake({
    Map<String, int> counts = const {},
    Map<String, int> lookups = const {},
    int status = 200,
  }) {
    calls.clear();
    return MockClient((req) async {
      calls.add(req.url);
      if (status != 200) return http.Response('nope', status);
      if (req.url.path.endsWith('/v1/taxa')) {
        final q = req.url.queryParameters['q']!;
        final id = lookups[q];
        return http.Response(
          jsonEncode({
            'results': [
              if (id != null) {'id': id, 'name': q},
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'results': [
            for (final e in counts.entries)
              {
                'count': e.value,
                'taxon': {'id': int.parse(e.key), 'name': 'x'},
              },
          ],
        }),
        200,
      );
    });
  }

  Future<void> taxon(String name, {String? inatId, String? synonyms}) async {
    final now = nowUtcIso();
    await db
        .into(db.taxa)
        .insert(
          TaxaCompanion.insert(
            id: newId(),
            scientificName: name,
            inatTaxonId: Value(inatId),
            synonyms: Value(synonyms),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  test('off by default: nothing is sent unless it is switched on', () async {
    await taxon('Quercus buckleyi', inatId: '167640');
    final rc = RangeCheck(db, client: fake());
    final out = await rc.countsNear(
      scientificNames: const ['Quercus buckleyi'],
      lat: 31.0618,
      lng: -98.1806,
    );
    expect(out, isEmpty);
    expect(calls, isEmpty, reason: 'a caller that forgets the flag sends nothing');
  });

  test('a candidate with no records nearby comes back as a real zero',
      () async {
    await taxon('Quercus buckleyi', inatId: '167640');
    await taxon('Quercus rubra', inatId: '49005');
    final rc = RangeCheck(db, client: fake(counts: {'167640': 64}));

    final out = await rc.countsNear(
      scientificNames: const ['Quercus buckleyi', 'Quercus rubra'],
      lat: 31.0618,
      lng: -98.1806,
      enabled: true,
    );

    expect(out['Quercus buckleyi'], 64);
    expect(
      out['Quercus rubra'],
      0,
      reason: 'species_counts omits a taxon it found nothing for; that '
          'absence is the zero',
    );
  });

  test('ids already in the library cost no extra request', () async {
    await taxon('Quercus buckleyi', inatId: '167640');
    await taxon('Melia azedarach', inatId: '53720');
    final rc = RangeCheck(db, client: fake(counts: {'167640': 64}));

    await rc.countsNear(
      scientificNames: const ['Quercus buckleyi', 'Melia azedarach'],
      lat: 31.06,
      lng: -98.18,
      enabled: true,
    );

    expect(calls, hasLength(1), reason: 'one request for every candidate');
    expect(calls.single.path, endsWith('/v1/observations/species_counts'));
    expect(calls.single.queryParameters['taxon_id'], contains(','));
  });

  test('the coordinate is rounded to about a kilometre before it leaves',
      () async {
    await taxon('Quercus buckleyi', inatId: '167640');
    final rc = RangeCheck(db, client: fake(counts: {'167640': 1}));
    await rc.countsNear(
      scientificNames: const ['Quercus buckleyi'],
      lat: 31.061847,
      lng: -98.180612,
      enabled: true,
    );
    final q = calls.single.queryParameters;
    expect(q['lat'], '31.06');
    expect(q['lng'], '-98.18');
    expect(calls.single.toString(), isNot(contains('31.061847')));
  });

  test('a name the library has never seen is looked up and remembered',
      () async {
    final rc = RangeCheck(
      db,
      client: fake(
        counts: {'12345': 7},
        lookups: {'Ratibida columnifera': 12345},
      ),
    );
    final out = await rc.countsNear(
      scientificNames: const ['Ratibida columnifera'],
      lat: 31.06,
      lng: -98.18,
      enabled: true,
    );
    expect(out['Ratibida columnifera'], 7);
    expect(calls.first.path, endsWith('/v1/taxa'));
  });

  test('a fuzzy name match is refused rather than borrowed', () async {
    // iNaturalist answering with a different species would otherwise hang
    // that plant's records on this candidate.
    final rc = RangeCheck(
      db,
      client: fake(lookups: {'Quercus buckleyi': 999}),
    );
    final out = await rc.countsNear(
      scientificNames: const ['Quercus not-a-real-oak'],
      lat: 31.06,
      lng: -98.18,
      enabled: true,
    );
    expect(out, isEmpty);
  });

  test('a synonym finds the row that already carries the id', () async {
    await taxon(
      'Prosopis glandulosa',
      inatId: '1493134',
      synonyms: 'Neltuma glandulosa',
    );
    final rc = RangeCheck(db, client: fake(counts: {'1493134': 318}));
    final out = await rc.countsNear(
      scientificNames: const ['Neltuma glandulosa'],
      lat: 31.06,
      lng: -98.18,
      enabled: true,
    );
    expect(out['Neltuma glandulosa'], 318);
    expect(calls, hasLength(1), reason: 'no lookup needed for a synonym');
  });

  test('a failed request leaves the candidates untouched', () async {
    await taxon('Quercus buckleyi', inatId: '167640');
    final rc = RangeCheck(db, client: fake(status: 503));
    final out = await rc.countsNear(
      scientificNames: const ['Quercus buckleyi'],
      lat: 31.06,
      lng: -98.18,
      enabled: true,
    );
    expect(out, isEmpty, reason: 'never an exception into the identify path');
  });

  test('the wording says recorded, never occurs', () async {
    expect(RangeCheck.note(null), isNull);
    expect(RangeCheck.note(64), contains('recorded'));
    expect(RangeCheck.note(1), contains('1 iNaturalist record '));
    final zero = RangeCheck.note(0)!;
    expect(zero, contains('not proof it is absent'));
    expect(zero.toLowerCase(), isNot(contains('does not occur')));
  });
}
