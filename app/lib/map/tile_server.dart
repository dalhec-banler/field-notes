import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

import 'mbtiles_store.dart';
import 'pmtiles_reader.dart';

/// Loopback HTTP server for offline basemaps (spec §3.4).
///
/// MapLibre Native's pmtiles:// protocol needs a fully-specified HTTP URL and
/// reads archives via Range requests, so offline basemaps are served from
/// 127.0.0.1 on an ephemeral port rather than bundled by relative path.
///
/// `/mbtiles/{z}/{x}/{y}.pbf` serves captured areas out of the MBTiles store
/// and, when a sideloaded PMTiles archive is also present, falls through to
/// it for tiles the capture didn't cover — so capturing one pasture never
/// blanks the county map around it.
class TileServer {
  TileServer._(this._server, this.root, this._fallback);

  final HttpServer _server;
  final Directory root;
  final PmTilesReader? _fallback;

  int get port => _server.port;

  /// URL for a file under [root], e.g. `urlFor('basemap.pmtiles')`.
  String urlFor(String fileName) => 'http://127.0.0.1:$port/$fileName';

  /// pmtiles:// source URL for MapLibre.
  String pmtilesUrlFor(String fileName) => 'pmtiles://${urlFor(fileName)}';

  /// z/x/y template for the merged endpoint.
  String get mbtilesUrlTemplate =>
      'http://127.0.0.1:$port/mbtiles/{z}/{x}/{y}.pbf';

  /// Deepest zoom the fallback archive carries, if any.
  int? get fallbackMaxZoom => _fallback?.header.maxZoom;

  static Future<TileServer> start(
    Directory root, {
    MbTilesStore? mbtiles,
    File? pmtilesFallback,
  }) async {
    PmTilesReader? fallback;
    if (pmtilesFallback != null && pmtilesFallback.existsSync()) {
      try {
        fallback = await PmTilesReader.open(FileRangeSource(pmtilesFallback));
      } catch (_) {
        fallback = null; // a bad archive just means no fallback
      }
    }

    final static = createStaticHandler(root.path);
    Future<Response> handler(Request req) async {
      final segs = req.url.pathSegments;
      if ((mbtiles != null || fallback != null) &&
          segs.length == 4 &&
          segs[0] == 'mbtiles') {
        final z = int.tryParse(segs[1]);
        final x = int.tryParse(segs[2]);
        final y = int.tryParse(segs[3].replaceAll('.pbf', ''));
        if (z == null || x == null || y == null) {
          return Response.badRequest();
        }
        var data = mbtiles?.getTile(z, x, y);
        if (data == null && fallback != null) {
          try {
            data = await fallback.getTile(z, x, y);
          } catch (_) {
            data = null;
          }
        }
        if (data == null) return Response.notFound('no tile');
        // Tiles are stored gzip'd; declare it so MapLibre inflates.
        final gzipped = data.length >= 2 && data[0] == 0x1f && data[1] == 0x8b;
        return Response.ok(
          data,
          headers: {
            'Content-Type': 'application/x-protobuf',
            if (gzipped) 'Content-Encoding': 'gzip',
          },
        );
      }
      return static(req);
    }

    final server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
    );
    return TileServer._(server, root, fallback);
  }

  Future<void> close() async {
    _fallback?.close();
    await _server.close(force: true);
  }
}
