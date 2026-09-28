import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../db/database.dart';

/// How often a candidate has been recorded near here, from iNaturalist.
///
/// The other two layers give opinions: Pl@ntNet sees the photograph, the
/// re-ranker sees the photograph and knows the region the way a language
/// model knows anything. This one is evidence — how many research-grade
/// records of that plant people have actually filed within a radius.
///
/// It does not produce candidates and it never rejects one. It annotates,
/// and a person still accepts. A northern red oak scored highly off a leaf
/// shot, with no record of one inside fifty kilometres, is a candidate worth
/// doubting, and that is the whole job.
///
/// **A zero means unrecorded, not absent.** iNaturalist is what people
/// photographed, which runs heavily to showy flowers and big trees. Grasses,
/// sedges and small forbs are badly under-recorded, so a count near zero on
/// one of those says nothing about whether it grows here. Everything this
/// returns is phrased as "recorded nearby" for that reason, and the UI must
/// not upgrade it to "occurs here".
///
/// Off unless the user turns it on, enforced here rather than at the call
/// site, because a lookup sends a coordinate (D-022's rule). The coordinate
/// is rounded to two decimal places first — about a kilometre, and at these
/// radii the rounding costs nothing.
class RangeCheck {
  RangeCheck(this.db, {http.Client? client})
    : _client = client ?? http.Client();

  final FieldNotesDb db;
  final http.Client _client;

  static const _host = 'api.inaturalist.org';
  static const _ua = 'FieldNotes/1.1 (field journal)';

  /// ~1 km. The same coarsening `EnvContext` applies before it asks anyone
  /// anything: the count needs the neighbourhood, not the plant's address.
  static double coarse(double v) => (v * 100).round() / 100;

  /// Records of each name within [radiusKm], keyed by the name as given.
  ///
  /// A name that comes back absent is a genuine zero: `species_counts` only
  /// returns taxa it found. Returns an empty map when the feature is off, no
  /// name could be resolved to an iNaturalist taxon, or the request failed —
  /// a failed lookup leaves the candidates exactly as they were.
  Future<Map<String, int>> countsNear({
    required List<String> scientificNames,
    required double lat,
    required double lng,
    int radiusKm = 50,
    bool enabled = false,
  }) async {
    if (!enabled || scientificNames.isEmpty) return const {};
    try {
      final ids = await _taxonIds(scientificNames);
      if (ids.isEmpty) return const {};

      final uri = Uri.https(_host, '/v1/observations/species_counts', {
        'taxon_id': ids.values.toSet().join(','),
        'lat': '${coarse(lat)}',
        'lng': '${coarse(lng)}',
        'radius': '$radiusKm',
        'quality_grade': 'research',
        'per_page': '200',
      });
      final res = await _client.get(uri, headers: {'User-Agent': _ua});
      if (res.statusCode != 200) return const {};

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final byId = <int, int>{};
      for (final r in (body['results'] as List?) ?? const []) {
        final m = r as Map<String, dynamic>;
        final taxon = m['taxon'] as Map<String, dynamic>?;
        final id = taxon?['id'] as int?;
        if (id != null) byId[id] = (m['count'] as num?)?.toInt() ?? 0;
      }
      return {
        for (final name in scientificNames)
          if (ids[name] != null) name: byId[ids[name]] ?? 0,
      };
    } catch (_) {
      return const {};
    }
  }

  /// iNaturalist taxon ids for [names].
  ///
  /// The library already knows most of them: the state list stores the id it
  /// was fetched with, so a candidate that is already a row costs no request
  /// at all. Only a name the library has never seen is looked up, and the id
  /// is written back so it is free next time.
  Future<Map<String, int>> _taxonIds(List<String> names) async {
    final out = <String, int>{};
    final rows = await (db.select(
      db.taxa,
    )..where((t) => t.deletedAt.isNull())).get();
    final known = <String, TaxaData>{};
    for (final t in rows) {
      known[_key(t.scientificName)] = t;
      for (final syn in (t.synonyms ?? '').split(';')) {
        if (syn.trim().isNotEmpty) known.putIfAbsent(_key(syn), () => t);
      }
    }

    for (final name in names) {
      final row = known[_key(name)];
      final id = int.tryParse(row?.inatTaxonId ?? '');
      if (id != null) {
        out[name] = id;
        continue;
      }
      final looked = await _lookup(name);
      if (looked == null) continue;
      out[name] = looked;
      if (row != null && row.inatTaxonId == null) {
        await (db.update(
          db.taxa,
        )..where((t) => t.id.equals(row.id))).write(
          TaxaCompanion(
            inatTaxonId: Value('$looked'),
            updatedAt: Value(nowUtcIso()),
          ),
        );
      }
    }
    return out;
  }

  Future<int?> _lookup(String name) async {
    try {
      final uri = Uri.https(_host, '/v1/taxa', {
        'q': name,
        'rank': 'species',
        'per_page': '1',
      });
      final res = await _client.get(uri, headers: {'User-Agent': _ua});
      if (res.statusCode != 200) return null;
      final results =
          ((jsonDecode(res.body) as Map<String, dynamic>)['results'] as List?) ??
          const [];
      if (results.isEmpty) return null;
      final first = results.first as Map<String, dynamic>;
      // Only accept an exact name match: a fuzzy hit would attach somebody
      // else's records to this candidate.
      if (_key('${first['name']}') != _key(name)) return null;
      return first['id'] as int?;
    } catch (_) {
      return null;
    }
  }

  static String _key(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// One line for a candidate, or null when there is nothing to say.
  ///
  /// Deliberately "recorded nearby" and never "occurs here" — see the class
  /// comment on what a zero does and does not mean.
  static String? note(int? count, {int radiusKm = 50}) {
    if (count == null) return null;
    if (count == 0) {
      return 'No iNaturalist records within $radiusKm km — '
          'not proof it is absent, but worth a second look.';
    }
    return '$count iNaturalist record${count == 1 ? '' : 's'} '
        'recorded within $radiusKm km.';
  }
}
