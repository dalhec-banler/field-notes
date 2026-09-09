import 'dart:convert';

import 'package:field_notes/backup/key_cache.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:field_notes/sync/shared_properties.dart';
import 'package:field_notes/sync/sharing_service.dart';
import 'package:field_notes/services/app_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_relay.dart';

/// D-031: the owner seals and shares; a member joins with a code and the
/// passphrase; the relay holds the envelope and nothing it can open.
void main() {
  late FakeRelay relay;
  late FieldNotesDb owner, member;
  late OpLog logOwner, logMember;
  late AppPrefs ownerPrefs, memberPrefs;

  setUp(() async {
    relay = FakeRelay();
    owner = FieldNotesDb.forTesting();
    member = FieldNotesDb.forTesting();
    logOwner = await OpLog.install(owner, deviceId: 'phone');
    logMember = await OpLog.install(member, deviceId: 'w-phone');
    ownerPrefs = AppPrefs.inMemory({'relay_url': 'https://relay.test'});
    memberPrefs = AppPrefs.inMemory({'relay_url': 'https://relay.test'});
  });
  tearDown(() async {
    await owner.close();
    await member.close();
  });

  Future<Property> place(FieldNotesDb db) async {
    final now = nowUtcIso();
    return db
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
  }

  test(
    'share writes the envelope; join unlocks it with the passphrase',
    () async {
      final p = await place(owner);
      final sharing = SharingService(
        owner,
        ownerPrefs,
        logOwner,
        client: relay.client(),
        keyCache: (_) => BackupKeyCache(),
      );
      final r = await sharing.share(
        property: p,
        passphrase: 'shared secret',
        displayName: 'Austin',
      );
      expect(r.shared.role, 'owner');
      expect(r.recoveryPhrase.split(' '), hasLength(12));
      expect(ownerPrefs.sharedProperties.single.propertyId, p.id);

      // The relay holds the keyring envelope: salts and wrapped keys, no key.
      final envelope = jsonDecode(
        utf8.decode(relay.objects['${p.id}/fieldnotes/manifest.json']!),
      ) as Map;
      expect(envelope['scheme'], 'keyring-v1');
      expect(envelope['wrap_pass'], isNotNull);
      expect(envelope.containsKey('data_key'), isFalse);

      final code = await sharing.invite(r.shared);
      final joining = SharingService(
        member,
        memberPrefs,
        logMember,
        client: relay.client(),
        keyCache: (_) => BackupKeyCache(),
      );
      final j = await joining.join(
        code: code.code,
        passphrase: 'shared secret',
        displayName: 'Wylder',
      );
      expect(j.unlocked, isTrue);
      expect(j.shared.propertyId, p.id);
      expect(j.shared.role, 'editor');
      expect(memberPrefs.sharedProperties.single.name, 'Shorts');

      final names = await joining.members(j.shared);
      expect(names.map((m) => m.displayName), ['Austin', 'Wylder']);
    },
  );

  test('a wrong passphrase still seats the member and says so', () async {
    final p = await place(owner);
    final sharing = SharingService(
      owner,
      ownerPrefs,
      logOwner,
      client: relay.client(),
      keyCache: (_) => BackupKeyCache(),
    );
    final r = await sharing.share(
      property: p,
      passphrase: 'right',
      displayName: 'Austin',
    );
    final code = await sharing.invite(r.shared);
    final joining = SharingService(
      member,
      memberPrefs,
      logMember,
      client: relay.client(),
      keyCache: (_) => BackupKeyCache(),
    );
    final j = await joining.join(
      code: code.code,
      passphrase: 'wrong',
      displayName: 'Wylder',
    );
    expect(j.unlocked, isFalse);
    expect(
      memberPrefs.sharedProperties,
      hasLength(1),
      reason: 'the seat is taken; the key is retried later',
    );
    await joining.leave(j.shared);
    expect(memberPrefs.sharedProperties, isEmpty);
  });
}
