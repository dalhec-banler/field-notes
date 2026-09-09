import 'dart:convert';
import 'dart:typed_data';

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
          final ownDir = path.startsWith('sync/${who.device}/');
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
