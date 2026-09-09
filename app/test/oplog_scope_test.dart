import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-030 rule 7: a shared folder carries one property — its rows and the
/// library — and never a row that says where the owner's other land is.
void main() {
  late FieldNotesDb a, b;
  late OpLog logA, logB;
  late Directory work;
  late DirectoryTarget store;

  Future<String> seedProperty(FieldNotesDb db, String name) async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: name,
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<String> addObservation(
    FieldNotesDb db,
    String propId,
    String notes,
  ) async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: id,
            propertyId: propId,
            observedAt: now,
            localTz: 'America/Chicago',
            lat: 31.06,
            lng: -98.05,
            notes: Value(notes),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<String> addTaxon(FieldNotesDb db, String name) async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.taxa)
        .insert(
          TaxaCompanion.insert(
            id: id,
            scientificName: name,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  setUp(() async {
    a = FieldNotesDb.forTesting();
    b = FieldNotesDb.forTesting();
    logA = await OpLog.install(a, deviceId: 'device-a');
    logB = await OpLog.install(b, deviceId: 'device-b');
    work = Directory.systemTemp.createTempSync('oplog_scope');
    store = DirectoryTarget(work);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    work.deleteSync(recursive: true);
  });

  test(
    'a property store carries that property and the library, nothing else',
    () async {
      final shorts = await seedProperty(a, 'Shorts');
      final home = await seedProperty(a, 'Home');
      final onShorts = await addObservation(a, shorts, 'cedar break');
      final atHome = await addObservation(a, home, 'back yard');
      final taxon = await addTaxon(a, 'Juniperus ashei');

      final scope = SyncScope.property(shorts);
      var pushed = 0;
      while (true) {
        final n = await logA.push(store, allowPlaintext: true, scope: scope);
        if (n == 0) break;
        pushed += n;
      }
      // Shorts, its record, the taxon — not Home or its record.
      expect(pushed, 3);

      await logB.pull(store, allowPlaintext: true, scope: scope);
      expect(
        await (b.select(b.properties)).get().then((r) => r.map((p) => p.name)),
        ['Shorts'],
      );
      final obs = await (b.select(b.observations)).get();
      expect(obs.map((o) => o.id), [onShorts]);
      expect(obs.map((o) => o.id), isNot(contains(atHome)));
      expect(
        (await (b.select(b.taxa)).get()).map((t) => t.id),
        contains(taxon),
      );

      // The app store's own mark is untouched by a property store's push.
      expect(await logA.meta('pushed_seq'), isNull);
      expect(await logA.meta(scope.metaKey('pushed_seq')), isNotNull);
    },
  );

  test('a deletion travels through a property store', () async {
    final shorts = await seedProperty(a, 'Shorts');
    final obsId = await addObservation(a, shorts, 'gone soon');
    final scope = SyncScope.property(shorts);
    await logA.push(store, allowPlaintext: true, scope: scope);
    await logB.pull(store, allowPlaintext: true, scope: scope);
    expect(await (b.select(b.observations)).get(), hasLength(1));

    await (a.delete(a.observations)..where((o) => o.id.equals(obsId))).go();
    expect(await logA.push(store, allowPlaintext: true, scope: scope), 1);
    await logB.pull(store, allowPlaintext: true, scope: scope);
    expect(await (b.select(b.observations)).get(), isEmpty);
  });

  test('a batch carrying another property is skipped on the way in', () async {
    final shorts = await seedProperty(a, 'Shorts');
    final home = await seedProperty(a, 'Home');
    await addObservation(a, shorts, 'ours');
    await addObservation(a, home, 'not for this folder');
    // A confused peer writes everything into the Shorts folder.
    await logA.push(store, allowPlaintext: true);

    final res = await logB.pull(
      store,
      allowPlaintext: true,
      scope: SyncScope.property(shorts),
    );
    expect(res.skipped, 2, reason: 'Home and its record refused');
    expect(res.applied, 2, reason: 'Shorts and its record applied');
    expect((await (b.select(b.properties)).get()).map((p) => p.name), [
      'Shorts',
    ]);
  });
}
