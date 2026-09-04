import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'imagery_capture.dart';
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
        final res = await c.get(
          Uri.parse(url),
          headers: {'Range': 'bytes=0-13'},
        );
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
    double minLon,
    double minLat,
    double maxLon,
    double maxLat,
  ) {
    // Deepest zoom that stays under the cap; never below 12, never above 15.
    for (var maxZ = 15; maxZ >= 12; maxZ--) {
      final n = TileMath.coverCount(
        minLon,
        minLat,
        maxLon,
        maxLat,
        minZ: 0,
        maxZ: maxZ,
      );
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
            'Could not reach build.protomaps.com — try on Wi-Fi',
          );
        }
        rangeSource = HttpRangeSource(url);
      }
      reader = await PmTilesReader.open(rangeSource);

      final (_, maxZ) = estimate(minLon, minLat, maxLon, maxLat);
      final wantedMaxZ = maxZ.clamp(
        reader.header.minZoom,
        reader.header.maxZoom,
      );
      final tiles = TileMath.cover(
        minLon,
        minLat,
        maxLon,
        maxLat,
        minZ: 0,
        maxZ: wantedMaxZ,
      );

      final file = await target();
      final createdNew = !file.existsSync();
      store = MbTilesStore.open(file, create: true);
      var done = 0;
      var written = 0;
      var inBatch = 0;
      _cancelled = false;
      store.begin();
      try {
        for (final (z, x, y) in tiles) {
          if (_cancelled) break;
          if (store.getTile(z, x, y) == null) {
            final data = await reader.getTile(z, x, y);
            if (data != null) {
              store.putTile(z, x, y, data);
              written++;
              // One fsync per batch, not per tile — and a readable store
              // for the map every few hundred tiles.
              if (++inBatch >= 200) {
                store.commit();
                store.begin();
                inBatch = 0;
              }
            }
          }
          done++;
          if (done % 20 == 0 || done == tiles.length) {
            progress = done / tiles.length;
            status = '$done of ${tiles.length} tiles';
            notifyListeners();
          }
        }
      } finally {
        store.commit();
      }
      final prior = store.metadata;
      final priorMax = int.tryParse(prior['maxzoom'] ?? '') ?? 0;
      store.setMetadata({
        'name': 'Field Notes capture',
        'format': 'pbf',
        'minzoom': '0',
        'maxzoom': '${wantedMaxZ > priorMax ? wantedMaxZ : priorMax}',
        'bounds': '$minLon,$minLat,$maxLon,$maxLat',
        'attribution': '© OpenStreetMap contributors · Protomaps',
      });
      if (_cancelled) {
        status = 'Stopped · kept $written tiles';
      } else {
        // Vector done: hi-res NAIP imagery (public domain) rides along so
        // the captured area has real pixels offline too (2026-09-04).
        var imgWrote = 0;
        try {
          status = 'Hi-res imagery…';
          notifyListeners();
          imgWrote = await ImageryCapture.capture(
            minLon,
            minLat,
            maxLon,
            maxLat,
            basemapDir: file.parent,
            onStatus: (s) {
              status = s;
              notifyListeners();
            },
            isCancelled: () => _cancelled,
          );
        } catch (_) {
          // Imagery is a bonus; the vector capture already landed.
        }
        status = imgWrote > 0
            ? 'Captured $written map + $imgWrote imagery tiles · offline'
            : 'Captured $written new tiles · offline';
      }
      // A capture that got nothing must not leave an empty store behind —
      // the map would prefer it over the regional file and go blank.
      if (createdNew && store.tileCount == 0) {
        store.close();
        store = null;
        for (final suffix in const ['', '-wal', '-shm', '-journal']) {
          final s = File('${file.path}$suffix');
          if (s.existsSync()) s.deleteSync();
        }
      }
    } catch (e) {
      error = '$e';
      status = null;
      // Same rule on failure.
      try {
        final s = store;
        if (s != null && s.tileCount == 0) {
          s.close();
          store = null;
          for (final suffix in const ['', '-wal', '-shm', '-journal']) {
            final f = File('${s.file.path}$suffix');
            if (f.existsSync()) f.deleteSync();
          }
        }
      } catch (_) {}
    } finally {
      reader?.close();
      store?.close();
      progress = null;
      notifyListeners();
    }
  }

  bool _cancelled = false;

  /// Stop after the current tile; what's already stored stays.
  void cancel() => _cancelled = true;
}
