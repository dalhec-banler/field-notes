import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

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

  static Future<TileServer> start(Directory root) async {
    final handler = const Pipeline().addHandler(
      createStaticHandler(root.path),
    );
    final server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
    );
    return TileServer._(server, root);
  }

  Future<void> close() => _server.close(force: true);
}
