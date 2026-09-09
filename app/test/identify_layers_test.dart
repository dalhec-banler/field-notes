import 'dart:io';

import 'package:field_notes/db/database.dart';
import 'package:field_notes/id/id_keys.dart';
import 'package:field_notes/id/id_models.dart';
import 'package:field_notes/id/identification_service.dart';
import 'package:field_notes/id/llm_client.dart';
import 'package:field_notes/id/plantnet_client.dart';
import 'package:field_notes/services/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Two identification layers, and one failing must not take the other's
/// answer with it (Austin, 2026-09-09): an empty OpenAI account used to
/// throw red text over a good Pl@ntNet result.
class _PlantNet extends PlantNetClient {
  _PlantNet(this.answer, {this.fail = false});
  final List<IdCandidate> answer;
  final bool fail;
  @override
  Future<List<IdCandidate>> identify({
    required List<File> photos,
    required String apiKey,
    String project = 'k-world-flora',
    String organ = 'auto',
    int maxResults = 5,
  }) async {
    if (fail) throw const PlantNetException('Pl@ntNet quota reached.');
    return answer;
  }
}

class _Llm extends LlmClient {
  _Llm({this.fail = false, this.answer = const []});
  final bool fail;
  final List<IdCandidate> answer;
  @override
  Future<List<IdCandidate>> rerank({
    required File photo,
    required IdContext context,
    required List<IdCandidate> priors,
    required LlmProvider provider,
    required String apiKey,
    required String model,
    required String baseUrl,
  }) async {
    if (fail) throw const LlmException(LlmException.outOfCredits);
    return answer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FieldNotesDb db;
  late Property property;
  late Observation obs;
  late File photo;
  late Directory work;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    work = Directory.systemTemp.createTempSync('id_layers');
    final now = nowUtcIso();
    property = await db
        .into(db.properties)
        .insertReturning(
          PropertiesCompanion.insert(
            id: newId(),
            name: 'Shorts',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    obs = await db
        .into(db.observations)
        .insertReturning(
          ObservationsCompanion.insert(
            id: newId(),
            propertyId: property.id,
            observedAt: now,
            localTz: 'America/Chicago',
            lat: 31.06,
            lng: -98.05,
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    photo = File('${work.path}/leaf.jpg')
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 64)));
  });
  tearDown(() async {
    await db.close();
    work.deleteSync(recursive: true);
  });

  /// Keys in a throwaway file: the host has no keystore.
  Future<IdKeys> keys({bool plantNet = true, bool llm = true}) async {
    final k = IdKeys(
      store: SecretStore(file: File('${work.path}/secrets.json')),
    );
    if (plantNet) await k.setPlantNetKey('pn-key');
    if (llm) {
      await k.setLlmKey('sk-key');
      await k.setLlmProvider(LlmProvider.openai);
    }
    return k;
  }

  final oak = IdCandidate(
    name: 'Quercus fusiformis',
    commonName: 'Plateau live oak',
    score: 0.7,
    source: 'plantnet',
  );

  test('the model out of credits: Pl@ntNet answers, and a flag says who did not run', () async {
    final svc = IdentificationService(
      db,
      keys: await keys(),
      plantNet: _PlantNet([oak]),
      llm: _Llm(fail: true),
    );
    final results = await svc.identify(
      photos: [photo],
      observation: obs,
      property: property,
      persist: false,
    );
    expect(results.map((c) => c.name), ['Quercus fusiformis']);
    expect(svc.lastWarning, "OpenAI didn't run: ${LlmException.outOfCredits}");
  });

  test(
    'Pl@ntNet down: the model answers alone, with the flag on Pl@ntNet',
    () async {
      final svc = IdentificationService(
        db,
        keys: await keys(),
        plantNet: _PlantNet([], fail: true),
        llm: _Llm(answer: [oak]),
      );
      final results = await svc.identify(
        photos: [photo],
        observation: obs,
        property: property,
        persist: false,
      );
      expect(results, hasLength(1));
      expect(svc.lastWarning, startsWith("Pl@ntNet didn't run"));
    },
  );

  test(
    'only the model, and it is out of credits: the run fails, in words',
    () async {
      final svc = IdentificationService(
        db,
        keys: await keys(plantNet: false),
        plantNet: _PlantNet([]),
        llm: _Llm(fail: true),
      );
      await expectLater(
        svc.identify(
          photos: [photo],
          observation: obs,
          property: property,
          persist: false,
        ),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'message',
            LlmException.outOfCredits,
          ),
        ),
      );
    },
  );

  test('both fine: no flag', () async {
    final svc = IdentificationService(
      db,
      keys: await keys(),
      plantNet: _PlantNet([oak]),
      llm: _Llm(answer: [oak]),
    );
    await svc.identify(
      photos: [photo],
      observation: obs,
      property: property,
      persist: false,
    );
    expect(svc.lastWarning, isNull);
  });
}
