import 'package:drift/drift.dart';

import 'database.dart';

/// Other scientific names for the seed species (D-032): the names a
/// plant carried before a revision, a variety's species-level name, an
/// old spelling. Identification matches the library on the accepted name
/// OR any of these, so Pl@ntNet answering "Dermatophyllum secundiflorum"
/// finds the row a person knows as Sophora, and answering "Platanus
/// occidentalis" finds the Texas sycamore rather than making a twin.
///
/// Conservative on purpose: a name here must mean THIS plant and no other
/// in Central Texas. Keyed by the seed's accepted name; a row filed under
/// one of the synonyms is served too (see [applySeedSynonyms]).
const seedSynonyms = <String, List<String>>{
  'Quercus fusiformis': ['Quercus virginiana var. fusiformis'],
  'Quercus sinuata var. breviloba': [
    'Quercus sinuata',
    'Quercus durandii var. breviloba',
  ],
  'Celtis laevigata var. laevigata': ['Celtis laevigata'],
  'Celtis laevigata var. reticulata': ['Celtis reticulata'],
  'Prunus serotina var. eximia': [
    'Prunus serotina',
    'Prunus serotina subsp. eximia',
  ],
  'Acer grandidentatum': [
    'Acer saccharum subsp. grandidentatum',
    'Acer saccharum var. grandidentatum',
  ],
  'Arbutus xalapensis': ['Arbutus texana'],
  'Mahonia trifoliolata': ['Berberis trifoliolata'],
  'Forestiera pubescens': ['Forestiera neomexicana'],
  'Rhus lanceolata': ['Rhus copallinum var. lanceolata'],
  'Platanus occidentalis var. glabrata': ['Platanus occidentalis'],
  'Cercis canadensis var. texensis': ['Cercis canadensis', 'Cercis texensis'],
  'Bouteloua dactyloides': ['Buchloe dactyloides'],
  'Schizachyrium scoparium': ['Andropogon scoparius'],
  'Panicum obtusum': ['Hopia obtusa'],
  'Schoenoplectus pungens': ['Scirpus pungens'],
  'Phyla nodiflora': ['Lippia nodiflora'],
  'Centaurea americana': ['Plectocephalus americanus'],
  'Engelmannia peristenia': ['Engelmannia pinnatifida'],
  'Liatris punctata': ['Liatris punctata var. mucronata', 'Liatris mucronata'],
  'Ratibida columnifera': ['Ratibida columnaris'],
  'Fraxinus albicans': ['Fraxinus texensis'],
  'Sapindus saponaria var. drummondii': [
    'Sapindus drummondii',
    'Sapindus saponaria',
  ],
  'Sideroxylon lanuginosum': ['Bumelia lanuginosa'],
  'Aesculus glabra var. arguta': ['Aesculus glabra', 'Aesculus arguta'],
  'Dermatophyllum secundiflorum': [
    'Sophora secundiflora',
    'Calia secundiflora',
  ],
  'Ziziphus obtusifolia': ['Condalia obtusifolia'],
  'Mimosa aculeaticarpa var. biuncifera': ['Mimosa biuncifera'],
  'Vachellia farnesiana': ['Acacia farnesiana', 'Acacia smallii'],
  'Aloysia gratissima': ['Lippia ligustrina'],
  'Frangula caroliniana': ['Rhamnus caroliniana'],
  'Opuntia engelmannii': [
    'Opuntia lindheimeri',
    'Opuntia engelmannii var. lindheimeri',
  ],
  'Toxicodendron radicans': ['Rhus radicans', 'Rhus toxicodendron'],
  'Nassella leucotricha': ['Stipa leucotricha'],
  'Bothriochloa laguroides': [
    'Andropogon saccharoides',
    'Bothriochloa saccharoides',
  ],
  'Sporobolus compositus': ['Sporobolus asper'],
  'Leptochloa dubia': ['Disakisperma dubium'],
  'Tridens flavus': ['Triodia flava'],
  'Chasmanthium latifolium': ['Uniola latifolia'],
  'Salvia azurea': ['Salvia azurea var. grandiflora', 'Salvia pitcheri'],
  'Glandularia bipinnatifida': ['Verbena bipinnatifida'],
  'Tetraneuris scaposa': ['Hymenoxys scaposa'],
  'Symphyotrichum ericoides': ['Aster ericoides'],
  'Solidago altissima': ['Solidago canadensis var. scabra'],
  'Conoclinium coelestinum': ['Eupatorium coelestinum'],
  'Chamaecrista fasciculata': ['Cassia fasciculata'],
  'Wedelia texana': [
    'Zexmenia hispida',
    'Wedelia hispida',
    'Wedelia acapulcensis var. hispida',
  ],
  'Carya illinoinensis': ['Carya illinoensis'],
  'Bromus catharticus': ['Bromus unioloides', 'Bromus willdenowii'],
  'Bothriochloa ischaemum var. songarica': ['Bothriochloa ischaemum'],
  'Triadica sebifera': ['Sapium sebiferum'],
};

/// The '; '-joined synonyms for a seed row, or null.
String? seedSynonymsFor(String scientificName) {
  final list = seedSynonyms[scientificName];
  return list == null || list.isEmpty ? null : list.join('; ');
}

/// Split a stored synonyms string.
List<String> splitSynonyms(String? stored) => [
  for (final s in (stored ?? '').split(';'))
    if (s.trim().isNotEmpty) s.trim(),
];

/// Every name a taxon answers to, lower-cased: the accepted name and the
/// synonyms.
Set<String> namesOf(String scientificName, String? synonyms) => {
  scientificName.trim().toLowerCase(),
  for (final s in splitSynonyms(synonyms)) s.toLowerCase(),
};

/// Fill `synonyms` on library rows that have none, from [seedSynonyms].
/// A row filed under the accepted name gets its synonyms; a row filed
/// under one of the synonyms (an older library, or a name a person typed)
/// gets the accepted name and the others. Rows a person already gave
/// synonyms to are left alone. Used by the v9 upgrade and safe to repeat.
Future<int> applySeedSynonyms(FieldNotesDb db) async {
  final byName = <String, (String accepted, List<String> all)>{};
  for (final e in seedSynonyms.entries) {
    final all = [e.key, ...e.value];
    for (final n in all) {
      byName[n.toLowerCase()] = (e.key, all);
    }
  }
  final rows = await (db.select(
    db.taxa,
  )..where((t) => t.synonyms.isNull() | t.synonyms.equals(''))).get();
  var touched = 0;
  for (final t in rows) {
    final hit = byName[t.scientificName.trim().toLowerCase()];
    if (hit == null) continue;
    final others = [
      for (final n in hit.$2)
        if (n.toLowerCase() != t.scientificName.trim().toLowerCase()) n,
    ];
    if (others.isEmpty) continue;
    await (db.update(db.taxa)..where((x) => x.id.equals(t.id))).write(
      TaxaCompanion(synonyms: Value(others.join('; '))),
    );
    touched++;
  }
  return touched;
}
