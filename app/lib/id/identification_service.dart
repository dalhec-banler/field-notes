import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../db/database.dart';
import 'id_keys.dart';
import 'id_models.dart';
import 'llm_client.dart';
import 'plantnet_client.dart';

/// Runs the identification pipeline and records what it found.
///
/// Hard rule (spec §5, and the app's own promise): a machine identification
/// is **never** written to `observations.taxon_id`. Every suggestion is
/// stored in `identification_suggestions` and shown for the user to accept.
/// Acceptance is the only thing that names a plant.
class IdentificationService {
  IdentificationService(
    this.db, {
    IdKeys? keys,
    PlantNetClient? plantNet,
    LlmClient? llm,
  })  : _keys = keys ?? IdKeys(),
        _plantNet = plantNet ?? PlantNetClient(),
        _llm = llm ?? LlmClient();

  final FieldNotesDb db;
  final IdKeys _keys;
  final PlantNetClient _plantNet;
  final LlmClient _llm;

  Future<bool> get isConfigured async =>
      (await _keys.hasPlantNet) || (await _keys.hasLlm);

  /// Identify [photo] for [observation]. Returns candidates best-first.
  ///
  /// Pl@ntNet runs first when a key is present; the LLM then re-ranks with
  /// local context. Either layer alone still produces an answer — if only
  /// the LLM is configured it works from the photograph and context.
  Future<List<IdCandidate>> identify({
    required File photo,
    required Observation observation,
    required Property property,
    String organ = 'auto',
    String plantNetProject = 'k-world-flora',
    void Function(String status)? onStatus,
  }) async {
    var priors = <IdCandidate>[];

    if (await _keys.hasPlantNet) {
      onStatus?.call('Asking Pl@ntNet…');
      try {
        priors = await _plantNet.identify(
          photo: photo,
          apiKey: (await _keys.plantNetKey)!,
          project: plantNetProject,
          organ: organ,
        );
      } on PlantNetException {
        rethrow;
      } catch (e) {
        throw PlantNetException('Could not reach Pl@ntNet: $e');
      }
    }

    var candidates = priors;
    if (await _keys.hasLlm) {
      onStatus?.call('Weighing it against this place…');
      final context = await buildContext(observation, property);
      final reranked = await _llm.rerank(
        photo: photo,
        context: context,
        priors: priors,
        provider: await _keys.llmProvider,
        apiKey: (await _keys.llmKey)!,
        model: await _keys.llmModel,
        baseUrl: await _keys.llmBaseUrl,
      );
      if (reranked.isNotEmpty) candidates = reranked;
    }

    candidates = await _matchToLibrary(candidates, property.id);
    await _record(candidates, observation, plantNetProject);
    return candidates;
  }

  /// What this place is, for the re-ranker.
  Future<IdContext> buildContext(
      Observation observation, Property property) async {
    String? zoneName;
    String? zoneType;
    if (observation.zoneId != null) {
      final z = await (db.select(db.zones)
            ..where((x) => x.id.equals(observation.zoneId!)))
          .getSingleOrNull();
      zoneName = z?.name;
      zoneType = z?.zoneType;
    }
    String? soilSeries;
    String? soilDrainage;
    if (observation.envContextId != null) {
      final e = await (db.select(db.envContexts)
            ..where((x) => x.id.equals(observation.envContextId!)))
          .getSingleOrNull();
      soilSeries = e?.soilSeries;
      soilDrainage = e?.soilDrainageClass;
    }

    // What's been seen here, and what was deliberately planted here — the
    // strongest priors the app owns.
    final recorded = await db.customSelect(
      'SELECT DISTINCT COALESCE(t.common_name || \' (\' || t.scientific_name || \')\', '
      't.scientific_name) AS n FROM observations o '
      'JOIN taxa t ON t.id = o.taxon_id '
      'WHERE o.property_id = ? AND o.deleted_at IS NULL LIMIT 80',
      variables: [Variable.withString(property.id)],
      readsFrom: {db.observations, db.taxa},
    ).get();
    final planted = await db.customSelect(
      'SELECT DISTINCT t.scientific_name AS n FROM planting_events p '
      'JOIN taxa t ON t.id = p.taxon_id '
      'WHERE p.property_id = ? AND p.deleted_at IS NULL LIMIT 40',
      variables: [Variable.withString(property.id)],
      readsFrom: {db.plantingEvents, db.taxa},
    ).get();

    final when = DateTime.tryParse(observation.observedAt)?.toLocal();
    return IdContext(
      propertyName: property.name,
      county: property.county,
      state: property.state,
      // Rounded in describe(); the model needs the region, not the plant.
      lat: observation.gpsAccuracyM == -1 ? null : observation.lat,
      lng: observation.gpsAccuracyM == -1 ? null : observation.lng,
      zoneName: zoneName,
      zoneType: zoneType,
      soilSeries: soilSeries,
      soilDrainage: soilDrainage,
      month: when?.month,
      recordedHere: [for (final r in recorded) r.data['n'] as String],
      plantedHere: [for (final r in planted) r.data['n'] as String],
    );
  }

  /// Link candidates to taxa already in the library, so accepting one
  /// doesn't create a duplicate species.
  Future<List<IdCandidate>> _matchToLibrary(
      List<IdCandidate> candidates, String propertyId) async {
    final out = <IdCandidate>[];
    for (final c in candidates) {
      final match = await (db.select(db.taxa)
            ..where((t) =>
                t.scientificName.lower().equals(c.name.toLowerCase()) &
                t.deletedAt.isNull())
            ..limit(1))
          .getSingleOrNull();
      out.add(match == null ? c : c.copyWith(taxonId: match.id));
    }
    return out;
  }

  Future<void> _record(List<IdCandidate> candidates, Observation observation,
      String project) async {
    if (candidates.isEmpty) return;
    final now = nowUtcIso();
    await db.transaction(() async {
      for (var i = 0; i < candidates.length; i++) {
        final c = candidates[i];
        await db
            .into(db.identificationSuggestions)
            .insert(IdentificationSuggestionsCompanion.insert(
              id: newId(),
              propertyId: observation.propertyId,
              observationId: observation.id,
              source: c.source,
              sourceDetail: Value(c.source == 'plantnet' ? project : null),
              suggestedTaxonId: Value(c.taxonId),
              suggestedName: c.name,
              score: Value(c.score),
              rankPosition: Value(i + 1),
              reasoning: Value(c.reasoning),
              rawResponseJson: Value(jsonEncode({
                'name': c.name,
                'common_name': c.commonName,
                'score': c.score,
              })),
              createdBy: const Value('local'),
              createdAt: now,
              updatedAt: now,
            ));
      }
    });
  }

  /// The user accepted [candidate] for [observationId]. This is the only
  /// path that writes a species onto a record.
  Future<String> accept({
    required IdCandidate candidate,
    required String observationId,
    required String propertyId,
  }) async {
    final now = nowUtcIso();
    var taxonId = candidate.taxonId;
    return db.transaction(() async {
      if (taxonId == null) {
        // A species new to this library: add it, scoped to this property.
        final existing = await (db.select(db.taxa)
              ..where((t) =>
                  t.scientificName.lower().equals(candidate.name.toLowerCase()))
              ..limit(1))
            .getSingleOrNull();
        if (existing != null) {
          taxonId = existing.id;
        } else {
          taxonId = newId();
          await db.into(db.taxa).insert(TaxaCompanion.insert(
                id: taxonId!,
                propertyId: Value(propertyId),
                scientificName: candidate.name,
                commonName: Value(candidate.commonName),
                createdBy: const Value('identification'),
                createdAt: now,
                updatedAt: now,
              ));
        }
      }
      await (db.update(db.observations)
            ..where((o) => o.id.equals(observationId)))
          .write(ObservationsCompanion(
        taxonId: Value(taxonId),
        // Accepted from a suggestion, not seen with your own eyes.
        taxonConfidence: const Value('probable'),
        observationType: const Value('plant'),
        updatedAt: Value(now),
      ));
      await (db.update(db.identificationSuggestions)
            ..where((s) =>
                s.observationId.equals(observationId) &
                s.suggestedName.equals(candidate.name)))
          .write(IdentificationSuggestionsCompanion(
        accepted: const Value(1),
        suggestedTaxonId: Value(taxonId),
        updatedAt: Value(now),
      ));
      return taxonId!;
    });
  }

  void close() {
    _plantNet.close();
    _llm.close();
  }
}
