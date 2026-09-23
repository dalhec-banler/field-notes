import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/backup_crypto.dart';
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/app_prefs.dart';
import 'package:field_notes/services/media_store.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:field_notes/sync/shared_properties.dart';
import 'package:field_notes/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// D-028: two devices, one shared folder standing in for the Drive app
/// folder, the keyring's seal. A record and its photo born on the phone
/// reach the desk as a row AND a file; a desk edit comes back; a deletion
/// travels; paths never cross; a second sync has nothing to do.
class _Docs extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Docs(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
  @override
  Future<String?> getTemporaryPath() async => dir.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('shared properties', sharedPropertyTests);
  late FieldNotesDb phone, desk;
  late OpLog logPhone, logDesk;
  late Directory work, phoneDocs, deskDocs;
  late DirectoryTarget drive;
  late PassphraseCipher cipher;
  late AppPrefs prefs;

  Future<String> seedProperty(FieldNotesDb db) async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: 'Shorts',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  SyncService service(FieldNotesDb db, OpLog log, Directory docs) {
    PathProviderPlatform.instance = _Docs(docs);
    return SyncService(
      db,
      prefs,
      log,
      openTarget: ({required bool interactive}) async => drive,
      openCipher: (_, _) async => cipher,
      mediaAllowed: () async => true,
      media: MediaStore(db),
    );
  }

  setUp(() async {
    work = Directory.systemTemp.createTempSync('sync');
    phoneDocs = Directory('${work.path}/phone')..createSync();
    deskDocs = Directory('${work.path}/desk')..createSync();
    drive = DirectoryTarget(Directory('${work.path}/drive')..createSync());
    phone = FieldNotesDb.forTesting();
    desk = FieldNotesDb.forTesting();
    logPhone = await OpLog.install(phone, deviceId: 'phone');
    logDesk = await OpLog.install(desk, deviceId: 'desk');
    cipher = await PassphraseCipher.fromPassphrase(
      'correct horse',
      List<int>.filled(16, 7),
      memoryKiB: 1024,
      iterations: 1,
    );
    prefs = AppPrefs.inMemory({'drive_email': 'austin@example.com'});
  });

  tearDown(() async {
    await phone.close();
    await desk.close();
    work.deleteSync(recursive: true);
  });

  test('a record and its photo cross, an edit comes back, a delete travels', () async {
    final propId = await seedProperty(phone);
    // A photo captured on the phone: a real file under the phone's layout.
    PathProviderPlatform.instance = _Docs(phoneDocs);
    final jpeg = Uint8List.fromList(List<int>.generate(4000, (i) => i % 251));
    final media = await phone
        .into(phone.media)
        .insertReturning(
          MediaCompanion.insert(
            id: newId(),
            propertyId: propId,
            mediaType: 'audio', // bytes need not decode as an image
            localPath: Value('${phoneDocs.path}/a.m4a'),
            sha256: Value(sha256.convert(jpeg).toString()),
            bytes: Value(jpeg.length),
            capturedAt: const Value('2026-09-07T10:00:00Z'),
            createdBy: 'local',
            createdAt: nowUtcIso(),
            updatedAt: nowUtcIso(),
          ),
        );
    File(media.localPath!).writeAsBytesSync(jpeg);
    final obsId = newId();
    await phone
        .into(phone.observations)
        .insert(
          ObservationsCompanion.insert(
            id: obsId,
            propertyId: propId,
            observedAt: nowUtcIso(),
            localTz: 'America/Chicago',
            lat: 31.06,
            lng: -98.05,
            notes: const Value('from the field'),
            createdBy: 'local',
            createdAt: nowUtcIso(),
            updatedAt: nowUtcIso(),
          ),
        );

    final r1 = await service(
      phone,
      logPhone,
      phoneDocs,
    ).sync(interactive: false);
    expect(r1.failed, isFalse, reason: r1.summary);
    expect(r1.pushed, greaterThanOrEqualTo(3));
    expect(r1.mediaUp, 1);
    // Sealed on the carrier: no readable notes anywhere in the folder.
    for (final f in await drive.list('sync')) {
      expect(
        String.fromCharCodes(await drive.read(f)),
        isNot(contains('from the field')),
      );
    }

    final r2 = await service(desk, logDesk, deskDocs).sync(interactive: false);
    expect(r2.failed, isFalse, reason: r2.summary);
    expect(r2.applied, greaterThanOrEqualTo(3));
    expect(r2.mediaDown, 1);
    final onDesk = await (desk.select(
      desk.media,
    )..where((m) => m.id.equals(media.id))).getSingle();
    // The desk's path is its own, under its own documents — never the phone's.
    expect(onDesk.localPath, isNotNull);
    expect(onDesk.localPath, startsWith(deskDocs.path));
    expect(File(onDesk.localPath!).readAsBytesSync(), jpeg);
    expect(
      await logDesk.pendingCount,
      0,
      reason: 'filing a blob is not an edit',
    );

    // The desk edits the notes; the phone sees it.
    await (desk.update(
      desk.observations,
    )..where((o) => o.id.equals(obsId))).write(
      ObservationsCompanion(
        notes: const Value('desk says'),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    final r3 = await service(desk, logDesk, deskDocs).sync(interactive: false);
    expect(r3.pushed, 1);
    await service(phone, logPhone, phoneDocs).sync(interactive: false);
    final back = await (phone.select(
      phone.observations,
    )..where((o) => o.id.equals(obsId))).getSingle();
    expect(back.notes, 'desk says');
    // The phone's own file path survived the desk's media row coming back.
    final phoneMedia = await (phone.select(
      phone.media,
    )..where((m) => m.id.equals(media.id))).getSingle();
    expect(phoneMedia.localPath, '${phoneDocs.path}/a.m4a');

    // A deletion on the phone reaches the desk.
    await (phone.delete(
      phone.observations,
    )..where((o) => o.id.equals(obsId))).go();
    await service(phone, logPhone, phoneDocs).sync(interactive: false);
    await service(desk, logDesk, deskDocs).sync(interactive: false);
    expect(
      await (desk.select(
        desk.observations,
      )..where((o) => o.id.equals(obsId))).getSingleOrNull(),
      isNull,
    );

    // Quiet afterwards.
    final r4 = await service(desk, logDesk, deskDocs).sync(interactive: false);
    expect(r4.summary, 'Up to date');
    expect(await logPhone.pendingCount, 0);
    expect(await logDesk.pendingCount, 0);
  });

  test(
    'a big history goes up in bounded batches and comes down whole',
    () async {
      final propId = await seedProperty(phone);
      for (var i = 0; i < 1203; i++) {
        await phone
            .into(phone.observations)
            .insert(
              ObservationsCompanion.insert(
                id: newId(),
                propertyId: propId,
                observedAt: nowUtcIso(),
                localTz: 'UTC',
                lat: 31,
                lng: -98,
                notes: Value('n$i'),
                createdBy: 'local',
                createdAt: nowUtcIso(),
                updatedAt: nowUtcIso(),
              ),
            );
      }
      final up = await service(
        phone,
        logPhone,
        phoneDocs,
      ).sync(interactive: false);
      expect(up.pushed, 1204);
      expect((await drive.list('sync')).length, greaterThanOrEqualTo(3));
      final down = await service(
        desk,
        logDesk,
        deskDocs,
      ).sync(interactive: false);
      expect(down.applied, 1204);
      expect(await desk.select(desk.observations).get(), hasLength(1203));
    },
  );

  test('a desk born from the phone\'s copy does not re-author its history', () async {
    final propId = await seedProperty(phone);
    await phone
        .into(phone.observations)
        .insert(
          ObservationsCompanion.insert(
            id: newId(),
            propertyId: propId,
            observedAt: nowUtcIso(),
            localTz: 'UTC',
            lat: 31,
            lng: -98,
            createdBy: 'local',
            createdAt: nowUtcIso(),
            updatedAt: nowUtcIso(),
          ),
        );
    // The desk "restores" the phone's database: same rows, same sync
    // tables — built by the real installer, filled without capture.
    final copy = FieldNotesDb.forTesting();
    final asPhone = await OpLog.install(copy, deviceId: 'phone');
    await asPhone.quietly(() async {
      for (final t in [
        'properties',
        'observations',
        'sync_ops',
        'sync_meta',
        'sync_versions',
        'sync_clock',
      ]) {
        for (final row in await phone.customSelect('SELECT * FROM $t').get()) {
          final cols = row.data.keys.toList();
          await copy.customStatement(
            'INSERT OR REPLACE INTO $t (${cols.map((c) => '"$c"').join(', ')}) '
            'VALUES (${List.filled(cols.length, '?').join(', ')})',
            [for (final c in cols) row.data[c]],
          );
        }
      }
    });
    final adopted = await OpLog.install(copy, deviceId: 'desk-2');
    expect(
      await adopted.pendingCount,
      0,
      reason: 'inherited ops are the phone\'s to push',
    );
    expect(await adopted.meta('cursor_phone'), isNotNull);

    // The desk then edits one row and adds another: those are its own.
    final obs = await copy.select(copy.observations).get();
    await (copy.update(
      copy.observations,
    )..where((o) => o.id.equals(obs.first.id))).write(
      ObservationsCompanion(
        notes: const Value('desk'),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    await copy
        .into(copy.observations)
        .insert(
          ObservationsCompanion.insert(
            id: newId(),
            propertyId: propId,
            observedAt: nowUtcIso(),
            localTz: 'UTC',
            lat: 31,
            lng: -98,
            createdBy: 'local',
            createdAt: nowUtcIso(),
            updatedAt: nowUtcIso(),
          ),
        );
    expect(await adopted.pendingCount, 2);

    // A desk adopted under the old rule: identity already its own, the
    // phone's ops still in the journal, nothing ever pushed. Simulate by
    // re-inserting the phone's ops beneath its own, then reopening.
    final inherited = await phone.customSelect('SELECT * FROM sync_ops').get();
    await adopted.quietly(() async {
      for (final row in inherited) {
        final cols = row.data.keys.where((c) => c != 'seq').toList();
        await copy.customStatement(
          'INSERT INTO sync_ops (${cols.map((c) => '"$c"').join(', ')}) '
          'VALUES (${List.filled(cols.length, '?').join(', ')})',
          [for (final c in cols) row.data[c]],
        );
      }
    });
    final healed = await OpLog.install(copy, deviceId: 'desk-2');
    // The property op is the phone's and goes; the inherited op for the
    // record the desk edited stays (the desk now owns that row's version)
    // — a harmless older payload the phone will outrank.
    expect(await healed.pendingCount, 3);
    final props = await copy
        .customSelect(
          "SELECT COUNT(*) AS n FROM sync_ops WHERE table_name = 'properties'",
        )
        .getSingle();
    expect(props.data['n'], 0, reason: 'only what the desk itself wrote');
    await copy.close();
  });
}

/// D-031: a property shared through the relay travels in its own scope
/// with its own key, beside the app folder — and a member sees only it.
void sharedPropertyTests() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FieldNotesDb owner, member;
  late OpLog logOwner, logMember;
  late Directory work;
  late DirectoryTarget relay;
  late PassphraseCipher key;

  Future<String> place(FieldNotesDb db, String name) async {
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

  Future<void> record(FieldNotesDb db, String propId, String notes) async {
    final now = nowUtcIso();
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: newId(),
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
  }

  SyncService service(
    FieldNotesDb db,
    OpLog log,
    AppPrefs prefs,
    Directory docs,
  ) {
    PathProviderPlatform.instance = _Docs(docs);
    return SyncService(
      db,
      prefs,
      log,
      openTarget: ({required bool interactive}) async => null,
      openCipher: (_, _) async => null,
      mediaAllowed: () async => true,
      media: MediaStore(db),
      openSharedTarget: (_) => relay,
      openSharedCipher: (_, _, _, _) async => key,
    );
  }

  setUp(() async {
    work = Directory.systemTemp.createTempSync('shared');
    relay = DirectoryTarget(Directory('${work.path}/relay')..createSync());
    owner = FieldNotesDb.forTesting();
    member = FieldNotesDb.forTesting();
    logOwner = await OpLog.install(owner, deviceId: 'owner-phone');
    logMember = await OpLog.install(member, deviceId: 'member-phone');
    key = await PassphraseCipher.fromPassphrase(
      'shared secret',
      List<int>.filled(16, 3),
      memoryKiB: 1024,
      iterations: 1,
    );
  });

  tearDown(() async {
    await owner.close();
    await member.close();
    work.deleteSync(recursive: true);
  });

  test(
    'the member receives the shared property and none of the rest',
    () async {
      final shorts = await place(owner, 'Shorts');
      final home = await place(owner, 'Home');
      await record(owner, shorts, 'cedar');
      await record(owner, home, 'back yard');

      SharedProperty share(String role) => SharedProperty(
        propertyId: shorts,
        name: 'Shorts',
        relayUrl: 'https://relay.test',
        memberToken: 't-$role',
        role: role,
      );
      final ownerPrefs = AppPrefs.inMemory()..putSharedProperty(share('owner'));
      final memberPrefs = AppPrefs.inMemory()
        ..putSharedProperty(share('editor'));

      // No Drive on either side: the relay leg runs on its own.
      final r1 = await service(
        owner,
        logOwner,
        ownerPrefs,
        Directory('${work.path}/o')..createSync(),
      ).sync(interactive: true);
      expect(r1.failed, isFalse);
      expect(r1.pushed, 2, reason: 'Shorts and its record; Home stays home');
      expect(r1.problems, isEmpty);

      final r2 = await service(
        member,
        logMember,
        memberPrefs,
        Directory('${work.path}/m')..createSync(),
      ).sync(interactive: true);
      expect(r2.applied, 2);
      expect(
        (await (member.select(member.properties)).get()).map((p) => p.name),
        ['Shorts'],
      );
      expect(
        (await (member.select(member.observations)).get()).single.notes,
        'cedar',
      );

      // An edit from the member comes back to the owner.
      await record(member, shorts, 'seen by the member');
      await service(
        member,
        logMember,
        memberPrefs,
        Directory('${work.path}/m'),
      ).sync(interactive: true);
      final r3 = await service(
        owner,
        logOwner,
        ownerPrefs,
        Directory('${work.path}/o'),
      ).sync(interactive: true);
      expect(r3.applied, 1);
      expect(await (owner.select(owner.observations)).get(), hasLength(3));
      expect(
        await logOwner.meta(SyncScope.property(shorts).metaKey('last_sync_at')),
        isNotNull,
      );
    },
  );

  test('a viewer pulls and never pushes', () async {
    final shorts = await place(owner, 'Shorts');
    await record(owner, shorts, 'cedar');
    final ownerPrefs = AppPrefs.inMemory()
      ..putSharedProperty(
        SharedProperty(
          propertyId: shorts,
          name: 'Shorts',
          relayUrl: 'u',
          memberToken: 'o',
          role: 'owner',
        ),
      );
    final viewerPrefs = AppPrefs.inMemory()
      ..putSharedProperty(
        SharedProperty(
          propertyId: shorts,
          name: 'Shorts',
          relayUrl: 'u',
          memberToken: 'v',
          role: 'viewer',
        ),
      );
    await service(
      owner,
      logOwner,
      ownerPrefs,
      Directory('${work.path}/o')..createSync(),
    ).sync(interactive: true);
    final r = await service(
      member,
      logMember,
      viewerPrefs,
      Directory('${work.path}/m')..createSync(),
    ).sync(interactive: true);
    expect(r.applied, 2);
    await record(member, shorts, 'a viewer wrote this locally');
    final r2 = await service(
      member,
      logMember,
      viewerPrefs,
      Directory('${work.path}/m'),
    ).sync(interactive: true);
    expect(r2.pushed, 0);
    expect(await relay.list('fieldnotes/sync/member-phone'), isEmpty);
  });
}
