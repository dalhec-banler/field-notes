import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

import 'mbtiles_store.dart';

/// Loopback HTTP server for PMTiles basemaps (spec §3.4).
///
/// MapLibre Native's pmtiles:// protocol needs a fully-specified HTTP URL and
/// reads archives via Range requests, so offline basemaps are served from
/// 127.0.0.1 on an ephemeral port rather than bundled by relative path.
class TileServer {
  TileServer._(this._server, this.root);

  final HttpServer _server;
  final Directory root;

  int get port => _server.port;

  /// URL for a file under [root], e.g. `urlFor('basemap.pmtiles')`.
  String urlFor(String fileName) => 'http://127.0.0.1:$port/$fileName';

  /// pmtiles:// source URL for MapLibre.
  String pmtilesUrlFor(String fileName) => 'pmtiles://${urlFor(fileName)}';

  static Future<TileServer> start(Directory root,
      {MbTilesStore? mbtiles}) async {
    final static = createStaticHandler(root.path);
    Future<Response> handler(Request req) async {
      // /mbtiles/{z}/{x}/{y}.pbf — vector tiles out of the captured area
      // store. Tiles are stored gzip'd; declare it so MapLibre inflates.
      final segs = req.url.pathSegments;
      if (mbtiles != null &&
          segs.length == 4 &&
          segs[0] == 'mbtiles') {
        final z = int.tryParse(segs[1]);
        final x = int.tryParse(segs[2]);
        final y = int.tryParse(segs[3].replaceAll('.pbf', ''));
        if (z == null || x == null || y == null) {
          return Response.badRequest();
        }
        final data = mbtiles.getTile(z, x, y);
        if (data == null) return Response.notFound('no tile');
        final gzipped = data.length >= 2 &&
            data[0] == 0x1f &&
            data[1] == 0x8b;
        return Response.ok(data, headers: {
          'Content-Type': 'application/x-protobuf',
          if (gzipped) 'Content-Encoding': 'gzip',
        });
      }
      return static(req);
    }

    final server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
    );
    return TileServer._(server, root);
  }

  Future<void> close() => _server.close(force: true);
}
