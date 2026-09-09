import 'dart:typed_data';

import 'package:field_notes/backup/relay_target.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_relay.dart';

void main() {
  late FakeRelay relay;
  setUp(() => relay = FakeRelay());

  test(
    'create, invite, join: the second device reads what the first wrote',
    () async {
      final rc = RelayClient(
        baseUrl: 'https://relay.test',
        client: relay.client(),
      );
      final owner = await rc.createProperty(
        propertyId: 'p1',
        name: 'Shorts',
        displayName: 'Austin',
        deviceId: 'phone',
      );
      expect(owner.role, 'owner');
      final code = await rc.createJoinCode(
        propertyId: 'p1',
        token: owner.memberToken,
      );
      final member = await rc.join(
        code: code.code,
        displayName: 'Wylder',
        deviceId: 'w-phone',
      );
      expect(member.propertyId, 'p1');
      expect(member.role, 'editor');

      final a = RelayTarget(
        baseUrl: 'https://relay.test',
        propertyId: 'p1',
        token: owner.memberToken,
        client: relay.client(),
      );
      final b = RelayTarget(
        baseUrl: 'https://relay.test',
        propertyId: 'p1',
        token: member.memberToken,
        client: relay.client(),
      );
      await a.write(
        'sync/phone/000000000001-3.json.enc',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(await b.exists('sync/phone/000000000001-3.json.enc'), isTrue);
      expect(await b.read('sync/phone/000000000001-3.json.enc'), [1, 2, 3]);
      expect(await b.list('sync/'), ['sync/phone/000000000001-3.json.enc']);
      expect(await b.exists('sync/phone/nope'), isFalse);

      final info = await rc.property(
        propertyId: 'p1',
        token: member.memberToken,
      );
      expect((info.seatsUsed, info.seatsAllowed), (2, 2));
      final names = await rc.members(
        propertyId: 'p1',
        token: member.memberToken,
      );
      expect(names.map((m) => m.displayName), ['Austin', 'Wylder']);
    },
  );

  test(
    'a device may write only under its own sync dir; a third seat is refused',
    () async {
      final rc = RelayClient(
        baseUrl: 'https://relay.test',
        client: relay.client(),
      );
      final owner = await rc.createProperty(
        propertyId: 'p1',
        name: 'Shorts',
        displayName: 'Austin',
        deviceId: 'phone',
      );
      final code = await rc.createJoinCode(
        propertyId: 'p1',
        token: owner.memberToken,
      );
      final member = await rc.join(
        code: code.code,
        displayName: 'Wylder',
        deviceId: 'w-phone',
      );
      final b = RelayTarget(
        baseUrl: 'https://relay.test',
        propertyId: 'p1',
        token: member.memberToken,
        client: relay.client(),
      );
      await expectLater(
        b.write('sync/phone/000000000009-9.json.enc', Uint8List(1)),
        throwsA(
          isA<RelayException>().having((e) => e.forbidden, 'forbidden', isTrue),
        ),
      );
      await b.write(
        'fieldnotes/blobs/ab/abcd.enc',
        Uint8List(1),
      ); // blobs are anyone's

      final code2 = await rc.createJoinCode(
        propertyId: 'p1',
        token: owner.memberToken,
      );
      await expectLater(
        rc.join(code: code2.code, displayName: 'Third', deviceId: 't'),
        throwsA(
          isA<RelayException>().having(
            (e) => e.message,
            'message',
            contains('free plan seats 2'),
          ),
        ),
      );
    },
  );

  test('a removed member reads as a sentence, not a status', () async {
    final t = RelayTarget(
      baseUrl: 'https://relay.test',
      propertyId: 'p1',
      token: 'stale',
      client: relay.client(),
    );
    await expectLater(
      t.list('sync/'),
      throwsA(
        isA<RelayException>().having(
          (e) => e.unauthorized,
          'unauthorized',
          isTrue,
        ),
      ),
    );
  });
}
