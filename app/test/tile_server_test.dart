import 'dart:io';
import 'dart:typed_data';

import 'package:field_notes/map/tile_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// PMTiles is unusable without correct Range serving (spec §3.4), so this
/// test exercises the exact request shapes MapLibre issues.
void main() {
  late Directory dir;
  late TileServer server;
  late Uint8List data;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('tiles');
    data = Uint8List.fromList(List.generate(70000, (i) => i % 251));
    File('${dir.path}/basemap.pmtiles').writeAsBytesSync(data);
    server = await TileServer.start(dir);
  });

  tearDown(() async {
    await server.close();
    dir.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> get(String path, {String? range}) async {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(server.urlFor(path)));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    return req.close();
  }

  Future<Uint8List> body(HttpClientResponse res) async {
    final chunks = <int>[];
    await for (final c in res) {
      chunks.addAll(c);
    }
    return Uint8List.fromList(chunks);
  }

  test('serves full file with 200', () async {
    final res = await get('basemap.pmtiles');
    expect(res.statusCode, 200);
    expect(await body(res), data);
  });

  test('serves a bounded range with 206 and Content-Range', () async {
    // PMTiles header read: first 127 bytes.
    final res = await get('basemap.pmtiles', range: 'bytes=0-126');
    expect(res.statusCode, 206);
    expect(res.headers.value('content-range'), 'bytes 0-126/70000');
    expect(await body(res), data.sublist(0, 127));
  });

  test('serves a mid-file range', () async {
    final res = await get('basemap.pmtiles', range: 'bytes=65000-65999');
    expect(res.statusCode, 206);
    expect(await body(res), data.sublist(65000, 66000));
  });

  test(
    'unsatisfiable range returns 416 or full-file 200, never garbage',
    () async {
      final res = await get('basemap.pmtiles', range: 'bytes=90000-90010');
      expect(res.statusCode, anyOf(416, 200));
    },
  );

  test('missing file returns 404', () async {
    final res = await get('nope.pmtiles');
    expect(res.statusCode, 404);
  });

  test('binds loopback with an ephemeral port', () {
    expect(server.port, greaterThan(1024));
    expect(server.urlFor('x'), startsWith('http://127.0.0.1:'));
    expect(
      server.pmtilesUrlFor('x'),
      startsWith('pmtiles://http://127.0.0.1:'),
    );
  });
}
