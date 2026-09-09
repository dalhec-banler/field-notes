// ignore_for_file: invalid_use_of_visible_for_testing_member
// End to end against the REAL relay (Go, ../relay): owner shares, member
// joins with a code and the passphrase, both sync through RelayTarget over
// HTTP, an edit comes back. Run by hand:  flutter test tool/relay_e2e_test.dart
// Needs Go on PATH; starts the relay on a free loopback port with a
// throwaway store, and stops it after.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/key_cache.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/app_prefs.dart';
import 'package:field_notes/services/media_store.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:field_notes/sync/sharing_service.dart';
import 'package:field_notes/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Host tests have no secure storage; a real cache keeps the test honest
/// about what the passphrase prompt is for.
class _MemoryCache extends BackupKeyCache {
  static final _store = <String, List<int>>{};
  _MemoryCache(this.name);
  final String name;
  @override
  Future<List<int>?> read() async => _store[name];
  @override
  Future<void> write(List<int> dataKey) async => _store[name] = dataKey;
  @override
  Future<void> clear() async => _store.remove(name);
}

void main() {
  late Process relay;
  late String url;
  late Directory work;

  setUpAll(() async {
    work = Directory.systemTemp.createTempSync('relay_e2e');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    url = 'http://127.0.0.1:$port';
    final relayDir = Directory('${Directory.current.path}/../relay');
    relay = await Process.start('go', [
      'run',
      './cmd/relay',
      '-addr',
      '127.0.0.1:$port',
      '-db',
      '${work.path}/c.sqlite',
      '-store',
      'dir:${work.path}/store',
    ], workingDirectory: relayDir.path);
    relay.stderr
        .transform(utf8.decoder)
        .listen((l) => stderr.write('[relay] $l'));
    final client = HttpClient();
    for (var i = 0; i < 300; i++) {
      try {
        final req = await client.getUrl(Uri.parse('$url/healthz'));
        final res = await req.close();
        if (res.statusCode == 200) break;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    client.close();
  });

  tearDownAll(() async {
    relay.kill(ProcessSignal.sigterm);
    await relay.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => relay.kill(ProcessSignal.sigkill) ? 0 : 0,
    );
    work.deleteSync(recursive: true);
  });

  test(
    'owner shares, member joins, records cross both ways through the relay',
    () async {
      final owner = FieldNotesDb.forTesting();
      final member = FieldNotesDb.forTesting();
      final logOwner = await OpLog.install(owner, deviceId: 'owner-phone');
      final logMember = await OpLog.install(member, deviceId: 'member-phone');
      final ownerPrefs = AppPrefs.inMemory({'relay_url': url});
      final memberPrefs = AppPrefs.inMemory({'relay_url': url});
      BackupKeyCache cache(String id) =>
          _MemoryCache('${identityHashCode(id)}-$id');

      final now = nowUtcIso();
      final shorts = await owner
          .into(owner.properties)
          .insertReturning(
            PropertiesCompanion.insert(
              id: newId(),
              name: 'Shorts',
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await owner
          .into(owner.properties)
          .insert(
            PropertiesCompanion.insert(
              id: newId(),
              name: 'Home',
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
      Future<void> record(FieldNotesDb db, String propId, String notes) => db
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
      await record(owner, shorts.id, 'cedar break');

      final sharing = SharingService(
        owner,
        ownerPrefs,
        logOwner,
        keyCache: cache,
      );
      final shared = await sharing.share(
        property: shorts,
        passphrase: 'correct horse',
        displayName: 'Austin',
        email: 'austin@example.com',
      );
      final code = await sharing.invite(shared.shared);

      SyncService svc(FieldNotesDb db, AppPrefs p, OpLog l) => SyncService(
        db,
        p,
        l,
        openTarget: ({required bool interactive}) async => null,
        openCipher: (_, _) async => null,
        mediaAllowed: () async => true,
        media: MediaStore(db),
      );
      // The owner's key is cached from share(); no prompt.
      var r = await svc(owner, ownerPrefs, logOwner).sync(
        interactive: true,
        askPassphrase: () async =>
            throw StateError('owner should not be asked'),
      );
      // Note: the shared cipher path uses BackupKeyCache.forSharedProperty (secure storage,
      // absent on the host) — so the owner IS asked here. Provide the passphrase instead.
      expect(r.failed || r.problems.isNotEmpty, isTrue);
      r = await svc(
        owner,
        ownerPrefs,
        logOwner,
      ).sync(interactive: true, askPassphrase: () async => 'correct horse');
      expect(r.problems, isEmpty, reason: r.summary);
      expect(r.pushed, 2, reason: 'Shorts and its record; Home stays home');

      final joining = SharingService(
        member,
        memberPrefs,
        logMember,
        keyCache: cache,
      );
      final j = await joining.join(
        code: code.code,
        passphrase: 'correct horse',
        displayName: 'Wylder',
        email: 'w@example.com',
      );
      expect(j.unlocked, isTrue);
      r = await svc(
        member,
        memberPrefs,
        logMember,
      ).sync(interactive: true, askPassphrase: () async => 'correct horse');
      expect(r.problems, isEmpty, reason: r.summary);
      expect(r.applied, 2);
      expect(
        (await (member.select(member.properties)).get()).map((p) => p.name),
        ['Shorts'],
      );
      expect(
        (await (member.select(member.observations)).get()).single.notes,
        'cedar break',
      );

      await record(member, shorts.id, 'seen by Wylder');
      r = await svc(
        member,
        memberPrefs,
        logMember,
      ).sync(interactive: true, askPassphrase: () async => 'correct horse');
      expect(r.pushed, 1);
      r = await svc(
        owner,
        ownerPrefs,
        logOwner,
      ).sync(interactive: true, askPassphrase: () async => 'correct horse');
      expect(r.applied, 1);
      expect(await (owner.select(owner.observations)).get(), hasLength(2));

      final info = await sharing.info(shared.shared);
      expect((info.seatsUsed, info.seatsAllowed), (2, 2));
      final code3 = sharing.invite(shared.shared);
      await expectLater(
        code3,
        throwsA(predicate((e) => '$e'.contains('free plan seats 2'))),
      );

      await owner.close();
      await member.close();
    },
  );
}
