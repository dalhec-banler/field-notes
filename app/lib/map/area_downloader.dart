import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mbtiles_store.dart';
import 'pmtiles_reader.dart';

/// Crop-an-area basemap download: reads tiles for a bbox from the public
/// Protomaps planet build (OSM, ODbL) over range requests and stores them in
/// a local MBTiles the loopback server serves. The user frames the area on
/// the map; this owns it offline.
class AreaDownloader extends ChangeNotifier {
  AreaDownloader();

  static const mbtilesName = 'basemap.mbtiles';
  static const maxTiles = 12000; // hard cap — keeps downloads sane

  double? progress;
  String? status;
  String? error;
  bool get downloading => progress != null;

  static Future<File> target() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, 'basemap', mbtilesName));
  }

  static Future<bool> isInstalled() async => (await target()).existsSync();

  /// Latest planet build on build.protomaps.com (daily, named YYYYMMDD).
  static Future<String?> findLatestBuildUrl({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      var day = DateTime.now().toUtc();
      for (var i = 0; i < 7; i++) {
        final name =
            '${day.year}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}';
        final url = 'https://build.protomaps.com/$name.pmtiles';
        final res = await c.get(Uri.parse(url),
            headers: {'Range': 'bytes=0-13'});
        if ((res.statusCode == 206 || res.statusCode == 200) &&
            res.bodyBytes.length >= 8 &&
            String.fromCharCodes(res.bodyBytes.sublist(0, 7)) == 'PMTiles') {
          return url;
        }
        day = day.subtract(const Duration(days: 1));
      }
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Estimated tile count for a bbox at the standard zoom range.
  static (int count, int maxZ) estimate(
      double minLon, double minLat, double maxLon, double maxLat) {
    // Deepest zoom that stays under the cap; never below 12, never above 15.
    for (var maxZ = 15; maxZ >= 12; maxZ--) {
      final n = TileMath.coverCount(minLon, minLat, maxLon, maxLat,
          minZ: 0, maxZ: maxZ);
      if (n <= maxTiles || maxZ == 12) return (n, maxZ);
    }
    return (0, 12);
  }

  /// Downloads the area. Existing tiles in the store are kept (areas
  /// accumulate — capture several properties over time).
  Future<void> download(
    double minLon,
    double minLat,
    double maxLon,
    double maxLat, {
    String? sourceUrl,
    RangeSource? source, // test seam
  }) async {
    if (downloading) return;
    progress = 0;
    error = null;
    status = 'Finding the planet build…';
    notifyListeners();
    PmTilesReader? reader;
    MbTilesStore? store;
    try {
      RangeSource rangeSource;
      if (source != null) {
        rangeSource = source;
      } else {
        final url = sourceUrl ?? await findLatestBuildUrl();
        if (url == null) {
          throw const SocketException(
              'Could not reach build.protomaps.com — try on Wi-Fi');
        }
        rangeSource = HttpRangeSource(url);
      }
      reader = await PmTilesReader.open(rangeSource);

      final (_, maxZ) = estimate(minLon, minLat, maxLon, maxLat);
      final wantedMaxZ =
          maxZ.clamp(reader.header.minZoom, reader.header.maxZoom);
      final tiles = TileMath.cover(minLon, minLat, maxLon, maxLat,
          minZ: 0, maxZ: wantedMaxZ);

      store = MbTilesStore.open(await target(), create: true);
      var done = 0;
      var written = 0;
      for (final (z, x, y) in tiles) {
        if (store.getTile(z, x, y) == null) {
          final data = await reader.getTile(z, x, y);
          if (data != null) {
            store.putTile(z, x, y, data);
            written++;
          }
        }
        done++;
        if (done % 20 == 0 || done == tiles.length) {
          progress = done / tiles.length;
          status = '$done of ${tiles.length} tiles';
          notifyListeners();
        }
      }
      store.setMetadata({
        'name': 'Field Station capture',
        'format': 'pbf',
        'minzoom': '0',
        'maxzoom': '$wantedMaxZ',
        'bounds': '$minLon,$minLat,$maxLon,$maxLat',
        'attribution': '© OpenStreetMap contributors · Protomaps',
      });
      status = 'Captured $written new tiles · offline';
    } catch (e) {
      error = '$e';
      status = null;
    } finally {
      reader?.close();
      store?.close();
      progress = null;
      notifyListeners();
    }
  }
}
