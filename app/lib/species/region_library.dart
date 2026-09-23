import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../db/database.dart';
import '../db/seed.dart' show parseCsv;
import '../db/seed_synonyms.dart';
import 'state_places.dart';

/// The species library for wherever the place is (D-015, D-034).
///
/// Two sources, in order:
///  1. A bundled palette for the state — `assets/seed/states/XX.csv`, the
///     same columns as the old single seed. Offline, lands the moment the
///     state is known. Texas ships the Edwards Plateau working list; other
///     states ship when someone curates one.
///  2. The state's most-recorded plants from iNaturalist — fetched only
///     when the user asks, and the request carries the state and nothing
///     else. Native and introduced flags come from iNat's establishment
///     means for the state.
///
/// Rows are global (property_id NULL) and tagged by `created_by` —
/// 'seed:TX', 'inat:OH' — so every state's list can sit beside the others
/// and a second import never clobbers the first.
class RegionLibrary {
  RegionLibrary(this.db, {http.Client? client, this.loadAsset})
    : _client = client ?? http.Client();

  final FieldNotesDb db;
  final http.Client _client;

  /// Test seam: asset text by path, or null when the asset does not exist.
  final Future<String?> Function(String path)? loadAsset;

  static String seedTag(String usps) => 'seed:${usps.toUpperCase()}';
  static String inatTag(String usps) => 'inat:${usps.toUpperCase()}';

  Future<String?> _asset(String path) async {
    if (loadAsset != null) return loadAsset!(path);
    try {
      return await rootBundle.loadString(path);
    } catch (_) {
      return null;
    }
  }

  /// Does the library already hold a list for this state, from either
  /// source?
  Future<bool> hasListFor(String usps) async {
    final rows =
        await (db.select(db.taxa)
              ..where((t) => t.propertyId.isNull())
              ..where((t) => t.createdBy.isIn([seedTag(usps), inatTag(usps)]))
              ..limit(1))
            .get();
    return rows.isNotEmpty;
  }

  /// Is there a bundled palette for the state at all?
  Future<bool> hasBundledPalette(String usps) async =>
      (await _asset('assets/seed/states/${usps.toUpperCase()}.csv')) != null;

  /// Loads the bundled palette for a state into the global library, once.
  /// Returns rows inserted (0 when already there or no palette exists).
  ///
  /// An install seeded before palettes were per-state holds the Texas list
  /// untagged; that counts as Texas already loaded.
  Future<int> seedBundledPalette(String usps) async {
    final code = usps.toUpperCase();
    if (await hasListFor(code)) return 0;
    if (code == 'TX') {
      final legacy =
          await (db.select(db.taxa)
                ..where((t) => t.propertyId.isNull())
                ..where((t) => t.createdBy.isNull())
                ..limit(1))
              .get();
      if (legacy.isNotEmpty) return 0;
    }
    final text = await _asset('assets/seed/states/$code.csv');
    if (text == null) return 0;
    final rows = parseCsv(text);
    if (rows.length < 2) return 0;
    final header = rows.first;
    final col = {for (var i = 0; i < header.length; i++) header[i]: i};
    String? field(List<String> row, String name) {
      final i = col[name];
      if (i == null || i >= row.length) return null;
      final v = row[i].trim();
      return v.isEmpty ? null : v;
    }

    final existing = await _existingByScientificName();
    final now = nowUtcIso();
    var inserted = 0;
    await db.batch((batch) {
      for (final row in rows.skip(1)) {
        final scientific = field(row, 'scientific_name');
        if (scientific == null || existing.containsKey(scientific)) continue;
        batch.insert(
          db.taxa,
          TaxaCompanion.insert(
            id: newId(),
            scientificName: scientific,
            commonName: Value(field(row, 'common_name')),
            family: Value(field(row, 'family')),
            growthForm: Value(field(row, 'growth_form')),
            nativity: Value(field(row, 'nativity')),
            usdaPlantsSymbol: Value(field(row, 'usda_plants_symbol')),
            isFavorite: Value(field(row, 'is_favorite') == '1' ? 1 : 0),
            notes: Value(field(row, 'notes')),
            synonyms: Value(seedSynonymsFor(scientific)),
            createdBy: Value(seedTag(code)),
            createdAt: now,
            updatedAt: now,
          ),
        );
        inserted++;
      }
    });
    return inserted;
  }

  /// Every state a place is known to sit in gets its bundled palette.
  /// Runs at launch, fire-and-forget; safe to call any time.
  Future<int> seedForKnownStates() async {
    final props =
        await (db.select(db.properties)
              ..where((p) => p.deletedAt.isNull())
              ..where((p) => p.state.isNotNull()))
            .get();
    var total = 0;
    for (final usps in {for (final p in props) p.state!}) {
      try {
        total += await seedBundledPalette(usps);
      } catch (_) {
        // A bad palette file never blocks launch.
      }
    }
    return total;
  }

  Future<Map<String, TaxaData>> _existingByScientificName() async {
    final rows = await (db.select(
      db.taxa,
    )..where((t) => t.deletedAt.isNull())).get();
    return {for (final t in rows) t.scientificName: t};
  }

  // ---- iNaturalist: the state's most-recorded plants -----------------

  static const _inatHost = 'api.inaturalist.org';

  /// The plants people actually meet in a state: iNaturalist's
  /// research-grade species counts for the state, most-recorded first.
  /// One request per page; only the state's place id is in the URL.
  Future<List<StateSpecies>> fetchStateSpecies(
    String usps, {
    int nativeLimit = 300,
    int introducedLimit = 60,
  }) async {
    final placeId = inatStatePlaceIds[usps.toUpperCase()];
    if (placeId == null) {
      throw StateError('No iNaturalist place for $usps');
    }
    final out = <StateSpecies>[];
    out.addAll(await _page(placeId, native: true, limit: nativeLimit));
    out.addAll(await _page(placeId, native: false, limit: introducedLimit));
    return out;
  }

  Future<List<StateSpecies>> _page(
    int placeId, {
    required bool native,
    required int limit,
  }) async {
    final out = <StateSpecies>[];
    var page = 1;
    while (out.length < limit) {
      final perPage = (limit - out.length).clamp(1, 200);
      final uri = Uri.https(_inatHost, '/v1/observations/species_counts', {
        'place_id': '$placeId',
        'iconic_taxa': 'Plantae',
        'quality_grade': 'research',
        native ? 'native' : 'introduced': 'true',
        'per_page': '$perPage',
        'page': '$page',
      });
      final res = await _client.get(
        uri,
        headers: {'User-Agent': 'FieldNotes/1.1 (field journal)'},
      );
      if (res.statusCode != 200) {
        throw StateError('iNaturalist answered ${res.statusCode}');
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final results = (body['results'] as List?) ?? const [];
      if (results.isEmpty) break;
      for (final r in results) {
        final t = (r as Map)['taxon'] as Map?;
        if (t == null) continue;
        if (t['rank'] != 'species') continue;
        out.add(
          StateSpecies(
            inatTaxonId: '${t['id']}',
            scientificName: '${t['name']}',
            commonName: t['preferred_common_name'] as String?,
            nativity: native ? 'native' : 'introduced',
            observations: (r['count'] as num?)?.toInt() ?? 0,
          ),
        );
        if (out.length >= limit) break;
      }
      if (results.length < perPage) break;
      page++;
    }
    return out;
  }

  /// Writes fetched species into the global library, tagged for the
  /// state. A name already in the library gains the iNat id and a
  /// nativity if it had none; nothing else about it changes.
  Future<int> importStateSpecies(
    String usps,
    List<StateSpecies> species, {
    int favoriteTop = 40,
  }) async {
    final code = usps.toUpperCase();
    final existing = await _existingByScientificName();
    final now = nowUtcIso();
    var inserted = 0;
    var rank = 0;
    await db.batch((batch) {
      for (final s in species) {
        rank++;
        final have = existing[s.scientificName];
        if (have != null) {
          if (have.inatTaxonId == null || have.nativity == null) {
            batch.update(
              db.taxa,
              TaxaCompanion(
                inatTaxonId: have.inatTaxonId == null
                    ? Value(s.inatTaxonId)
                    : const Value.absent(),
                nativity: have.nativity == null
                    ? Value(s.nativity)
                    : const Value.absent(),
                updatedAt: Value(now),
              ),
              where: (t) => t.id.equals(have.id),
            );
          }
          continue;
        }
        batch.insert(
          db.taxa,
          TaxaCompanion.insert(
            id: newId(),
            scientificName: s.scientificName,
            commonName: Value(s.commonName),
            nativity: Value(s.nativity),
            inatTaxonId: Value(s.inatTaxonId),
            isFavorite: Value(
              s.nativity == 'native' && rank <= favoriteTop ? 1 : 0,
            ),
            notes: Value('${s.observations} iNaturalist records in $code'),
            createdBy: Value(inatTag(code)),
            createdAt: now,
            updatedAt: now,
          ),
        );
        inserted++;
      }
    });
    return inserted;
  }
}

class StateSpecies {
  const StateSpecies({
    required this.inatTaxonId,
    required this.scientificName,
    required this.commonName,
    required this.nativity,
    required this.observations,
  });

  final String inatTaxonId;
  final String scientificName;
  final String? commonName;

  /// 'native' | 'introduced'
  final String nativity;
  final int observations;
}
