import 'package:drift/drift.dart';

import 'seed_synonyms.dart';

/// Folds library rows that name the same plant down to one.
///
/// Two loaders wrote the library — the original seed and the state list — and
/// until this was fixed they only ever compared accepted names, and only
/// against a snapshot taken before the batch began. So a list naming a plant
/// twice inserted it twice, and a list using the other accepted name for a
/// plant that has been moved between genera (Agarita under both *Berberis*
/// and *Mahonia*, honey mesquite under both *Prosopis* and *Neltuma*) filed a
/// second row beside the first. The loader no longer does either. This clears
/// what it already wrote.
///
/// A split row is not cosmetic: observations hang off a taxon id, so two rows
/// means one plant's history on the property is recorded in two places and
/// neither is complete.
///
/// Rows are merged only within a scope — a property's own taxon is never
/// folded into the shared library, since that row belongs to whoever made it.

/// Every table that points at a taxon, and the column it points with. Missing
/// one here would orphan records against a row that is about to be retired.
/// (`detections.taxon_id` is not listed: the table is retired, nothing writes
/// it, and it goes with the next migration — docs/SCHEMA-RESERVED.md.)
const _taxonRefs = <String, String>{
  'observations': 'taxon_id',
  'identification_suggestions': 'suggested_taxon_id',
  'source_plants': 'taxon_id',
  'propagation_batches': 'taxon_id',
  'planting_events': 'taxon_id',
};

/// The subset of [_taxonRefs] this database actually has. A migration runs
/// against whatever schema the file arrived with, and an upgrade that dies on
/// a table introduced after that version leaves the database unopenable.
Future<Map<String, String>> _presentRefs(GeneratedDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
      .get();
  final have = rows.map((r) => r.read<String>('name')).toSet();
  return {
    for (final e in _taxonRefs.entries)
      if (have.contains(e.key)) e.key: e.value,
  };
}

/// Name as it is matched: trimmed, case-folded, inner spaces collapsed.
String taxonKey(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Name -> every name in its [seedSynonyms] group. Two rows can be the same
/// plant while neither one stores the other's name — the seed's *Prosopis*
/// mesquite and the list's *Neltuma* both arrived with an empty synonyms
/// column. The seed table is what knows they are one plant.
final _seedGroups = <String, Set<String>>{
  for (final e in seedSynonyms.entries)
    for (final n in [e.key, ...e.value])
      taxonKey(n): {for (final m in [e.key, ...e.value]) taxonKey(m)},
};

Iterable<String> _namesOf(String scientific, String? synonyms) sync* {
  for (final raw in [scientific, ...(synonyms ?? '').split(';')]) {
    final k = taxonKey(raw);
    if (k.isEmpty) continue;
    yield k;
    yield* _seedGroups[k] ?? const <String>{};
  }
}

/// Moves every record off [loserId] onto [keepId], fills the survivor's blank
/// columns from the row being retired, and soft-deletes it.
Future<void> _absorb(
  GeneratedDatabase db,
  String keepId,
  String loserId,
  String now,
) async {
  for (final e in (await _presentRefs(db)).entries) {
    await db.customStatement(
      'UPDATE ${e.key} SET ${e.value} = ? WHERE ${e.value} = ?',
      [keepId, loserId],
    );
  }
  // Anything the survivor left blank, take from the row being retired — the
  // loaders filled different columns.
  await db.customStatement('''
    UPDATE taxa SET
      common_name = COALESCE(common_name,
        (SELECT common_name FROM taxa WHERE id = ?2)),
      family = COALESCE(family, (SELECT family FROM taxa WHERE id = ?2)),
      growth_form = COALESCE(growth_form,
        (SELECT growth_form FROM taxa WHERE id = ?2)),
      nativity = COALESCE(nativity,
        (SELECT nativity FROM taxa WHERE id = ?2)),
      gbif_key = COALESCE(gbif_key,
        (SELECT gbif_key FROM taxa WHERE id = ?2)),
      inat_taxon_id = COALESCE(inat_taxon_id,
        (SELECT inat_taxon_id FROM taxa WHERE id = ?2)),
      usda_plants_symbol = COALESCE(usda_plants_symbol,
        (SELECT usda_plants_symbol FROM taxa WHERE id = ?2)),
      itis_tsn = COALESCE(itis_tsn,
        (SELECT itis_tsn FROM taxa WHERE id = ?2)),
      notes = COALESCE(notes, (SELECT notes FROM taxa WHERE id = ?2)),
      is_favorite = MAX(is_favorite,
        (SELECT is_favorite FROM taxa WHERE id = ?2))
    WHERE id = ?1''', [keepId, loserId]);
  await db.customStatement(
    'UPDATE taxa SET deleted_at = ?, updated_at = ? WHERE id = ?',
    [now, now, loserId],
  );
}

/// Adds [names] to a row's synonyms, minus its own accepted name.
Future<void> _setSynonyms(
  GeneratedDatabase db,
  String id,
  String accepted,
  Set<String> names,
  String now,
) async {
  final keep = names.where((n) => taxonKey(n) != taxonKey(accepted)).toList()
    ..sort();
  await db.customStatement(
    'UPDATE taxa SET synonyms = ?, updated_at = ? WHERE id = ?',
    [keep.isEmpty ? null : keep.join('; '), now, id],
  );
}

/// Merges duplicate taxa in place. Returns how many rows were retired.
Future<int> dedupeTaxa(GeneratedDatabase db, {required String now}) async {
  final rows = await db
      .customSelect(
        'SELECT id, property_id, scientific_name, synonyms, is_favorite, '
        'created_at FROM taxa WHERE deleted_at IS NULL',
      )
      .get();
  if (rows.isEmpty) return 0;

  // Group by any name in common. A row joins the group its accepted name or
  // any of its synonyms already belongs to, which is what lets the two
  // Agarita rows meet: one's accepted name is the other's synonym.
  final groupOf = <String, int>{}; // scope|name -> group
  final members = <int, List<QueryRow>>{};
  var next = 0;
  for (final r in rows) {
    final scope = r.read<String?>('property_id') ?? '';
    final keys = _namesOf(
      r.read<String>('scientific_name'),
      r.read<String?>('synonyms'),
    ).map((n) => '$scope|$n').toSet();

    final hit = keys.map((k) => groupOf[k]).whereType<int>().toSet();
    final g = hit.isEmpty ? next++ : hit.reduce((a, b) => a < b ? a : b);
    // A row can bridge two groups that hadn't met yet; pull them together.
    for (final other in hit.where((h) => h != g)) {
      members.remove(other)?.forEach(members.putIfAbsent(g, () => []).add);
      groupOf.updateAll((_, v) => v == other ? g : v);
    }
    for (final k in keys) {
      groupOf[k] = g;
    }
    members.putIfAbsent(g, () => []).add(r);
  }

  // How much history each row carries. The row records already point at is
  // the one to keep, so that re-pointing moves as little as possible.
  Future<int> refs(String id) async {
    var n = 0;
    for (final e in (await _presentRefs(db)).entries) {
      final c = await db
          .customSelect(
            'SELECT count(*) c FROM ${e.key} WHERE ${e.value} = ?',
            variables: [Variable<String>(id)],
          )
          .getSingle();
      n += c.read<int>('c');
    }
    return n;
  }

  var retired = 0;
  for (final group in members.values.where((m) => m.length > 1)) {
    final scored = <(QueryRow, int)>[];
    for (final r in group) {
      scored.add((r, await refs(r.read<String>('id'))));
    }
    // Most history wins; then the older row, which is the one a person has
    // most likely already seen in the list. Id last, so this is repeatable.
    scored.sort((a, b) {
      final byRefs = b.$2.compareTo(a.$2);
      if (byRefs != 0) return byRefs;
      final byAge = a.$1
          .read<String>('created_at')
          .compareTo(b.$1.read<String>('created_at'));
      return byAge != 0 ? byAge : a.$1.read<String>('id').compareTo(
        b.$1.read<String>('id'),
      );
    });

    final keep = scored.first.$1;
    final keepId = keep.read<String>('id');
    final losers = scored.skip(1).map((s) => s.$1).toList();

    // Keep every name the group answered to, so a later import that uses the
    // retired name finds this row instead of making a third one.
    final names = <String>{};
    for (final r in group) {
      for (final s in [
        r.read<String>('scientific_name'),
        ...(r.read<String?>('synonyms') ?? '').split(';'),
      ]) {
        if (s.trim().isNotEmpty) names.add(s.trim());
      }
    }

    for (final l in losers) {
      await _absorb(db, keepId, l.read<String>('id'), now);
      retired++;
    }

    await _setSynonyms(
      db,
      keepId,
      keep.read<String>('scientific_name'),
      names,
      now,
    );
  }
  return retired + await _adoptIdentifiedTwins(db, now);
}

/// Folds a property's own row back into the shared library when the
/// identification service made it by accident.
///
/// When a photo came back named *Neltuma glandulosa* and the library only
/// knew the mesquite as *Prosopis*, identification filed a new row against
/// the property rather than lose the record — so the list showed "Honey
/// Mesquite" and "Honey mesquite" side by side. The synonym now exists, so
/// this cannot happen again; the row it already made is folded in here.
///
/// Deliberately narrow. Only a row the service made moves, only into a
/// global row, and only when they share a name. A taxon a person entered
/// themselves is left where they put it.
Future<int> _adoptIdentifiedTwins(GeneratedDatabase db, String now) async {
  final globals = await db
      .customSelect(
        'SELECT id, scientific_name, synonyms FROM taxa '
        'WHERE deleted_at IS NULL AND property_id IS NULL',
      )
      .get();
  final byName = <String, String>{};
  for (final g in globals) {
    for (final n in _namesOf(
      g.read<String>('scientific_name'),
      g.read<String?>('synonyms'),
    )) {
      byName.putIfAbsent(n, () => g.read<String>('id'));
    }
  }

  final twins = await db
      .customSelect(
        "SELECT id, scientific_name, synonyms FROM taxa WHERE deleted_at "
        "IS NULL AND property_id IS NOT NULL AND created_by = 'identification'",
      )
      .get();

  var retired = 0;
  for (final t in twins) {
    final names = _namesOf(
      t.read<String>('scientific_name'),
      t.read<String?>('synonyms'),
    ).toSet();
    final keepId = names.map((n) => byName[n]).whereType<String>().firstOrNull;
    if (keepId == null) continue;

    final keep = await db
        .customSelect(
          'SELECT scientific_name, synonyms FROM taxa WHERE id = ?',
          variables: [Variable<String>(keepId)],
        )
        .getSingle();
    await _absorb(db, keepId, t.read<String>('id'), now);
    // The name the service used becomes a synonym, so the next photo that
    // comes back under it finds this row.
    await _setSynonyms(db, keepId, keep.read<String>('scientific_name'), {
      for (final r in [keep, t])
        ...[
          r.read<String>('scientific_name'),
          ...(r.read<String?>('synonyms') ?? '').split(';'),
        ].map((n) => n.trim()).where((n) => n.isNotEmpty),
    }, now);
    retired++;
  }
  return retired;
}
