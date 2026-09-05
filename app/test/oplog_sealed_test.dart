import 'dart:convert';
import 'dart:io';

import 'package:field_notes/backup/backup_crypto.dart';
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-026: what a shared folder is allowed to learn.
///
/// The external audit found sync batches written as readable JSON — full
/// row payloads, coordinates and notes — because encryption lived in the
/// backup engine and the oplog never called it. These tests hold the line
/// the audit drew: sealed batches are opaque, they still round-trip, a
/// batch cannot lie about who wrote it, and writing in the clear takes an
/// explicit acknowledgement.
void main() {
  late FieldNotesDb a, b;
  late Directory work;
  late DirectoryTarget store;

  Future<PassphraseCipher> cipher() => PassphraseCipher.fromPassphrase(
    'correct horse',
    List<int>.filled(16, 7),
    // Deliberately weak for tests only; production parameters are untouched.
    memoryKiB: 1024,
    iterations: 1,
  );

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

  setUp(() {
    a = FieldNotesDb.forTesting();
    b = FieldNotesDb.forTesting();
    work = Directory.systemTemp.createTempSync('oplog-sealed');
    store = DirectoryTarget(work);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    work.deleteSync(recursive: true);
  });

  test('a sealed batch tells the carrier nothing', () async {
    final log = await OpLog.install(a, deviceId: 'phone');
    await seedProperty(a, 'private location audit marker');
    expect(await log.push(store, cipher: await cipher()), greaterThan(0));

    final file = (await store.list('sync')).single;
    final wire = utf8.decode(await store.read(file), allowMalformed: true);
    expect(wire, isNot(contains('private location audit marker')));
    expect(wire, isNot(contains('properties')));
  });

  test('a sealed batch still carries the record to the other device', () async {
    final phone = await OpLog.install(a, deviceId: 'phone');
    final desk = await OpLog.install(b, deviceId: 'desk');
    final id = await seedProperty(a, 'Shorts Resort');
    await phone.push(store, cipher: await cipher());
    final res = await desk.pull(store, cipher: await cipher());

    expect(res.applied, greaterThan(0));
    final landed = await (b.select(
      b.properties,
    )..where((p) => p.id.equals(id))).getSingle();
    expect(landed.name, 'Shorts Resort');
  });

  test('the wrong key opens nothing', () async {
    final phone = await OpLog.install(a, deviceId: 'phone');
    await seedProperty(a, 'Shorts Resort');
    await phone.push(store, cipher: await cipher());

    final desk = await OpLog.install(b, deviceId: 'desk');
    final wrong = await PassphraseCipher.fromPassphrase(
      'wrong horse',
      List<int>.filled(16, 7),
      memoryKiB: 1024,
      iterations: 1,
    );
    await expectLater(
      desk.pull(store, cipher: wrong),
      throwsA(isA<StateError>()),
    );
  });

  test('a batch cannot claim to be from another device', () async {
    final phone = await OpLog.install(a, deviceId: 'phone');
    await seedProperty(a, 'Shorts Resort');
    await phone.push(store, allowPlaintext: true);

    // Move the batch into a directory it does not belong to.
    final file = (await store.list('sync')).single;
    final bytes = await store.read(file);
    await store.write(file.replaceFirst('/phone/', '/imposter/'), bytes);
    await store.delete(file);

    final desk = await OpLog.install(b, deviceId: 'desk');
    await expectLater(
      desk.pull(store, allowPlaintext: true),
      throwsA(isA<StateError>()),
    );
  });

  test('writing in the clear takes saying so', () async {
    final log = await OpLog.install(a, deviceId: 'phone');
    await seedProperty(a, 'Shorts Resort');
    await expectLater(log.push(store), throwsA(isA<StateError>()));
    await expectLater(log.pull(store), throwsA(isA<StateError>()));
    // A plain cipher is not a disguise for the clear.
    await expectLater(
      log.push(store, cipher: const PlainCipher()),
      throwsA(isA<StateError>()),
    );
  });
}
