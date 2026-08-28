import 'dart:convert';
import 'dart:typed_data';

import 'package:field_notes/backup/drive_target.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A Drive stand-in: enough of the v3 API to prove the target's contract.
/// The point of these tests is the two places DriveTarget can silently get
/// it wrong — the name encoding (Drive has no paths) and the id index
/// (which must survive a write without a re-list).
class _FakeDrive {
  final files = <String, Uint8List>{}; // id -> bytes
  final names = <String, String>{}; // id -> name
  int listCalls = 0;
  int _next = 0;

  String _id() => 'id${_next++}';

  http.Client client() => MockClient((request) async {
        final path = request.url.path;

        if (request.method == 'GET' && path == '/drive/v3/files') {
          listCalls++;
          return http.Response(
            jsonEncode({
              'files': [
                for (final e in names.entries)
                  {'id': e.key, 'name': e.value}
              ]
            }),
            200,
          );
        }

        if (request.method == 'GET' && path.startsWith('/drive/v3/files/')) {
          final id = path.split('/').last;
          return http.Response.bytes(files[id] ?? Uint8List(0), 200);
        }

        if (request.method == 'DELETE' && path.startsWith('/drive/v3/files/')) {
          final id = path.split('/').last;
          files.remove(id);
          names.remove(id);
          return http.Response('', 204);
        }

        if (path.startsWith('/upload/drive/v3/files')) {
          final body = request.bodyBytes;
          // Split the multipart body: metadata JSON, then the raw payload.
          final text = latin1.decode(body);
          final metaStart = text.indexOf('{');
          final metaEnd = text.indexOf('}\r\n--');
          final meta = jsonDecode(text.substring(metaStart, metaEnd + 1))
              as Map<String, dynamic>;
          final marker = 'application/octet-stream\r\n\r\n';
          final start = text.indexOf(marker) + marker.length;
          final end = text.lastIndexOf('\r\n--');
          final payload = Uint8List.fromList(body.sublist(start, end));

          final id = request.method == 'PATCH' ? path.split('/').last : _id();
          files[id] = payload;
          names[id] = meta['name'] as String;
          return http.Response(jsonEncode({'id': id}), 200);
        }

        return http.Response('unexpected ${request.method} $path', 404);
      });
}

void main() {
  late _FakeDrive drive;
  late DriveTarget target;

  setUp(() {
    drive = _FakeDrive();
    target = DriveTarget(accessToken: 'token', client: drive.client());
  });

  test('round-trips a nested path through a flat namespace', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 250, 0, 255]);
    await target.write('fieldnotes/blobs/ab/abcd.bin', bytes);

    expect(await target.exists('fieldnotes/blobs/ab/abcd.bin'), isTrue);
    expect(await target.read('fieldnotes/blobs/ab/abcd.bin'), bytes);
    // Stored flat — Drive never sees a directory.
    expect(drive.names.values.single, 'fieldnotes__blobs__ab__abcd.bin');
  });

  test('list returns decoded paths under a prefix only', () async {
    await target.write('fieldnotes/db/3.sqlite', Uint8List.fromList([1]));
    await target.write('fieldnotes/db/4.sqlite', Uint8List.fromList([2]));
    await target.write('fieldnotes/blobs/ab/x.bin', Uint8List.fromList([3]));

    final dumps = await target.list('fieldnotes/db');
    expect(dumps..sort(), ['fieldnotes/db/3.sqlite', 'fieldnotes/db/4.sqlite']);
  });

  test('the index is built once, not per blob', () async {
    // BackupEngine calls exists() once per blob; a query each time would
    // make a first backup unusably slow.
    await target.exists('fieldnotes/blobs/ab/a.bin');
    await target.exists('fieldnotes/blobs/ab/b.bin');
    await target.exists('fieldnotes/blobs/ab/c.bin');
    expect(drive.listCalls, 1);
  });

  test('re-writing a name updates that file, never a duplicate', () async {
    await target.write('fieldnotes/manifest.json', Uint8List.fromList([1]));
    await target.write('fieldnotes/manifest.json', Uint8List.fromList([9, 9]));

    expect(drive.names.length, 1, reason: 'a second file would orphan the first');
    expect(await target.read('fieldnotes/manifest.json'),
        Uint8List.fromList([9, 9]));
  });

  test('delete drops it from the index too', () async {
    await target.write('fieldnotes/db/1.sqlite', Uint8List.fromList([1]));
    await target.delete('fieldnotes/db/1.sqlite');
    expect(await target.exists('fieldnotes/db/1.sqlite'), isFalse);
    expect(drive.listCalls, 1, reason: 'delete must not force a re-list');
  });

  test('deleting something absent is not an error', () async {
    await target.delete('fieldnotes/db/nope.sqlite');
  });

  test('an expired token is reported in words, not JSON', () async {
    final dead = DriveTarget(
      accessToken: 'stale',
      client: MockClient((_) async => http.Response(
          jsonEncode({'error': {'message': 'Invalid Credentials'}}), 401)),
    );
    expect(
      () => dead.exists('fieldnotes/manifest.json'),
      throwsA(isA<DriveException>().having(
          (e) => e.message, 'message', contains('Open Backup'))),
    );
  });
}
