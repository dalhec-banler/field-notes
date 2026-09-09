import 'dart:convert';
import 'dart:typed_data';

import 'package:field_notes/backup/relay_target.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A relay in memory: the store endpoints with the layout rule (a device
/// writes only under its own sync dir, blobs, and — owner — the manifest),
/// and enough control plane to create, invite, join and count seats.
class FakeRelay {
  final objects = <String, Uint8List>{}; // '<prop>/<path>' → bytes
  final tokens = <String, ({String prop, String role, String device})>{};
  final codes = <String, String>{}; // code → prop
  final members = <String, List<Map<String, Object?>>>{};
  int seats = 2;

  http.Client client() => MockClient((req) async {
    final segs = req.url.pathSegments;
    final auth = req.headers['authorization']?.replaceFirst('Bearer ', '');
    final who = auth == null ? null : tokens[auth];
    if (segs.length == 2 && segs[1] == 'properties' && req.method == 'POST') {
      final b = jsonDecode(req.body) as Map;
      final prop = b['id'] as String;
      final tok = 'owner-$prop';
      tokens[tok] = (prop: prop, role: 'owner', device: b['device_id']);
      members[prop] = [
        {
          'id': 'm1',
          'display_name': b['display_name'],
          'role': 'owner',
          'devices': [b['device_id']],
        },
      ];
      return http.Response(
        jsonEncode({
          'property': {'id': prop, 'name': b['name']},
          'member_token': tok,
          'role': 'owner',
        }),
        200,
      );
    }
    if (segs.length == 2 && segs[1] == 'join' && req.method == 'POST') {
      final b = jsonDecode(req.body) as Map;
      final prop = codes[b['code']];
      if (prop == null)
        return http.Response(
          jsonEncode({'error': 'That code is not valid.'}),
          404,
        );
      if (members[prop]!.length >= seats) {
        return http.Response(
          jsonEncode({
            'error':
                'Shared with $seats people already; the free plan seats $seats.',
          }),
          403,
        );
      }
      final tok = 'member-${members[prop]!.length}-$prop';
      tokens[tok] = (prop: prop, role: 'editor', device: b['device_id']);
      members[prop]!.add({
        'id': 'm${members[prop]!.length + 1}',
        'display_name': b['display_name'],
        'role': 'editor',
        'devices': [b['device_id']],
      });
      return http.Response(
        jsonEncode({
          'property': {'id': prop, 'name': 'Shorts'},
          'member_token': tok,
          'role': 'editor',
        }),
        200,
      );
    }
    if (who == null)
      return http.Response(jsonEncode({'error': 'no token'}), 401);
    if (segs.length < 3 || segs[2] != who.prop) return http.Response('', 404);
    final prop = who.prop;
    if (segs.length == 4 && segs[3] == 'join-codes') {
      if (who.role != 'owner') return http.Response('', 403);
      final code = 'CODE${codes.length}';
      codes[code] = prop;
      return http.Response(
        jsonEncode({'code': code, 'expires_at': '2027-01-01T00:00:00Z'}),
        200,
      );
    }
    if (segs.length == 4 && segs[3] == 'members') {
      return http.Response(jsonEncode({'members': members[prop]}), 200);
    }
    if (segs.length == 3) {
      return http.Response(
        jsonEncode({
          'seats': {'used': members[prop]!.length, 'allowed': seats},
        }),
        200,
      );
    }
    if (segs[3] == 'store') {
      if (segs.length == 4) {
        final prefix = req.url.queryParameters['prefix'] ?? '';
        final names = [
          for (final k in objects.keys)
            if (k.startsWith('$prop/$prefix')) k.substring(prop.length + 1),
        ];
        return http.Response(jsonEncode({'names': names}), 200);
      }
      final path = segs.sublist(4).map(Uri.decodeComponent).join('/');
      final key = '$prop/$path';
      switch (req.method) {
        case 'HEAD':
          return http.Response('', objects.containsKey(key) ? 200 : 404);
        case 'GET':
          final b = objects[key];
          return b == null
              ? http.Response('', 404)
              : http.Response.bytes(b, 200);
        case 'PUT':
          if (who.role == 'viewer')
            return http.Response(
              jsonEncode({'error': 'viewers cannot write'}),
              403,
            );
          final ownDir = path.startsWith('fieldnotes/sync/${who.device}/');
          final blob = path.startsWith('fieldnotes/blobs/');
          final manifest =
              path == 'fieldnotes/manifest.json' && who.role == 'owner';
          if (!ownDir && !blob && !manifest) {
            return http.Response(
              jsonEncode({
                'error': 'a device writes only under its own sync dir',
              }),
              403,
            );
          }
          objects[key] = req.bodyBytes;
          return http.Response('', 201);
        case 'DELETE':
          objects.remove(key);
          return http.Response('', 204);
      }
    }
    return http.Response('', 500);
  });
}

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
        'fieldnotes/sync/phone/000000000001-3.json.enc',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(
        await b.exists('fieldnotes/sync/phone/000000000001-3.json.enc'),
        isTrue,
      );
      expect(await b.read('fieldnotes/sync/phone/000000000001-3.json.enc'), [
        1,
        2,
        3,
      ]);
      expect(await b.list('fieldnotes/sync/'), [
        'fieldnotes/sync/phone/000000000001-3.json.enc',
      ]);
      expect(await b.exists('fieldnotes/sync/phone/nope'), isFalse);

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
        b.write('fieldnotes/sync/phone/000000000009-9.json.enc', Uint8List(1)),
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
      t.list('fieldnotes/sync/'),
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
