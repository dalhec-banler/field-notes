import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'mbtiles_store.dart';

/// Offline hi-res imagery capture (Austin, 2026-09-04).
///
/// NAIP — USDA's ~0.6 m aerial program, PUBLIC DOMAIN — rendered
/// tile-by-tile from the USGS exportImage endpoint into
/// `imagery.mbtiles` beside the vector capture. Esri's sharper live
/// tiles may only be *displayed* (their terms forbid offline storage);
/// NAIP may be kept, so the captured area works offline at real
/// resolution and the loopback server prefers it when the network is
/// gone.
class ImageryCapture {
  static const fileName = 'imagery.mbtiles';
  static const _endpoint =
      'https://imagery.nationalmap.gov/arcgis/rest/services/USGSNAIPPlus/ImageServer/exportImage';

  /// Deepest zoom first, capped so a capture stays minutes, not hours.
  static const maxTiles = 3000;
  static const _minZ = 12;

  /// (tile count, deepest zoom) for the pre-download estimate.
  static (int, int) estimate(
    double minLon,
    double minLat,
    double maxLon,
    double maxLat,
  ) {
    for (var maxZ = 17; maxZ >= 13; maxZ--) {
      final n = TileMath.coverCount(
        minLon,
        minLat,
        maxLon,
        maxLat,
        minZ: _minZ,
        maxZ: maxZ,
      );
      if (n <= maxTiles || maxZ == 13) return (n, maxZ);
    }
    return (0, 13);
  }

  /// Web-mercator bbox (EPSG:3857 metres) for an XYZ tile.
  static String _bbox(int z, int x, int y) {
    const r = 6378137.0 * math.pi;
    final n = 1 << z;
    final mx0 = -r + x * 2 * r / n;
    final mx1 = -r + (x + 1) * 2 * r / n;
    final my1 = r - y * 2 * r / n;
    final my0 = r - (y + 1) * 2 * r / n;
    return '$mx0,$my0,$mx1,$my1';
  }

  /// Fetch NAIP for the bbox into `<basemapDir>/imagery.mbtiles`.
  /// Existing tiles are kept (areas accumulate). Returns tiles written.
  static Future<int> capture(
    double minLon,
    double minLat,
    double maxLon,
    double maxLat, {
    required Directory basemapDir,
    void Function(String status)? onStatus,
    bool Function()? isCancelled,
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    final ownClient = client == null;
    final (_, maxZ) = estimate(minLon, minLat, maxLon, maxLat);
    final tiles = TileMath.cover(
      minLon,
      minLat,
      maxLon,
      maxLat,
      minZ: _minZ,
      maxZ: maxZ,
    );
    final file = File('${basemapDir.path}/$fileName');
    final createdNew = !file.existsSync();
    final store = MbTilesStore.open(file, create: true);
    var written = 0;
    var done = 0;
    var inBatch = 0;
    store.begin();
    try {
      for (final (z, x, y) in tiles) {
        if (isCancelled?.call() ?? false) break;
        if (store.getTile(z, x, y) == null) {
          try {
            final uri = Uri.parse(
              '$_endpoint?bbox=${_bbox(z, x, y)}&bboxSR=3857&imageSR=3857'
              '&size=256,256&format=jpg&f=image',
            );
            final res = await c
                .get(uri, headers: {'User-Agent': 'FieldNotes/1.1'})
                .timeout(const Duration(seconds: 20));
            final b = res.bodyBytes;
            // A JPEG or nothing: the service answers errors as HTML/JSON.
            if (res.statusCode == 200 &&
                b.length > 3 &&
                b[0] == 0xFF &&
                b[1] == 0xD8) {
              store.putTile(z, x, y, b);
              written++;
              if (++inBatch >= 100) {
                store.commit();
                store.begin();
                inBatch = 0;
              }
            }
          } catch (_) {
            // One missed tile never fails a capture.
          }
        }
        done++;
        if (done % 10 == 0 || done == tiles.length) {
          onStatus?.call('Hi-res imagery · $done of ${tiles.length}');
        }
      }
    } finally {
      store.commit();
      final prior = store.metadata;
      final priorMax = int.tryParse(prior['maxzoom'] ?? '') ?? 0;
      store.setMetadata({
        'name': 'Field Notes imagery',
        'format': 'jpg',
        'minzoom': '$_minZ',
        'maxzoom': '${maxZ > priorMax ? maxZ : priorMax}',
        'bounds': '$minLon,$minLat,$maxLon,$maxLat',
        'attribution': 'USDA NAIP (public domain) via USGS',
      });
      final empty = store.tileCount == 0;
      store.close();
      if (createdNew && empty) {
        for (final suffix in const ['', '-wal', '-shm', '-journal']) {
          final s = File('${file.path}$suffix');
          if (s.existsSync()) s.deleteSync();
        }
      }
      if (ownClient) c.close();
    }
    return written;
  }
}
