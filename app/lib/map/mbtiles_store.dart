import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// Local MBTiles store — the spec's own fallback format (§3.4). Tiles are
/// stored TMS-flipped per the MBTiles spec; [getTile] takes XYZ and flips.
///
/// The map's reader and a running capture's writer share this file, so the
/// connection is opened in WAL mode with a busy timeout: a read landing
/// during a commit waits instead of failing the tile.
class MbTilesStore {
  MbTilesStore._(this._db, this.file);

  final Database _db;
  final File file;

  static MbTilesStore open(File file, {bool create = false}) {
    file.parent.createSync(recursive: true);
    final db = sqlite3.open(file.path);
    db.execute('PRAGMA busy_timeout = 2000');
    try {
      db.execute('PRAGMA journal_mode = WAL');
    } catch (_) {
      // Read-only media or an odd filesystem: rollback journal still works.
    }
    if (create) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS metadata (name TEXT, value TEXT);
        CREATE TABLE IF NOT EXISTS tiles (
          zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER,
          tile_data BLOB);
        CREATE UNIQUE INDEX IF NOT EXISTS tile_index
          ON tiles (zoom_level, tile_column, tile_row);
      ''');
    }
    return MbTilesStore._(db, file);
  }

  void close() => _db.close();

  /// Batch writes: one fsync per [commit] instead of one per tile.
  void begin() => _db.execute('BEGIN');
  void commit() => _db.execute('COMMIT');

  void setMetadata(Map<String, String> meta) {
    _db.execute('DELETE FROM metadata');
    final stmt = _db.prepare(
      'INSERT INTO metadata (name, value) VALUES (?, ?)',
    );
    for (final e in meta.entries) {
      stmt.execute([e.key, e.value]);
    }
    stmt.close();
  }

  Map<String, String> get metadata {
    final rows = _db.select('SELECT name, value FROM metadata');
    return {for (final r in rows) r['name'] as String: r['value'] as String};
  }

  void putTile(int z, int x, int y, Uint8List data) {
    final tms = (1 << z) - 1 - y;
    _db.execute(
      'INSERT OR REPLACE INTO tiles (zoom_level, tile_column, tile_row, '
      'tile_data) VALUES (?, ?, ?, ?)',
      [z, x, tms, data],
    );
  }

  Uint8List? getTile(int z, int x, int y) {
    final tms = (1 << z) - 1 - y;
    final rows = _db.select(
      'SELECT tile_data FROM tiles WHERE zoom_level = ? AND '
      'tile_column = ? AND tile_row = ?',
      [z, x, tms],
    );
    if (rows.isEmpty) return null;
    return rows.first['tile_data'] as Uint8List;
  }

  int get tileCount {
    final rows = _db.select('SELECT COUNT(*) AS n FROM tiles');
    return rows.first['n'] as int;
  }

  /// Union of every captured bbox is not tracked; the metadata `bounds` is the
  /// last capture's. Callers wanting "is anything here" should use [getTile].
}

/// Slippy-map tile math for area cropping.
class TileMath {
  static int lonToX(double lon, int z) =>
      (((lon + 180) / 360) * (1 << z)).floor().clamp(0, (1 << z) - 1);

  static int latToY(double lat, int z) {
    final rad = lat * math.pi / 180;
    final y =
        (1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) /
        2 *
        (1 << z);
    return y.floor().clamp(0, (1 << z) - 1);
  }

  /// All (z, x, y) covering the bbox from zoom [minZ] through [maxZ].
  static List<(int, int, int)> cover(
    double minLon,
    double minLat,
    double maxLon,
    double maxLat, {
    required int minZ,
    required int maxZ,
  }) {
    final tiles = <(int, int, int)>[];
    for (var z = minZ; z <= maxZ; z++) {
      final x0 = lonToX(minLon, z), x1 = lonToX(maxLon, z);
      final y0 = latToY(maxLat, z), y1 = latToY(minLat, z);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          tiles.add((z, x, y));
        }
      }
    }
    return tiles;
  }

  /// Count without materialising — for the pre-download estimate.
  static int coverCount(
    double minLon,
    double minLat,
    double maxLon,
    double maxLat, {
    required int minZ,
    required int maxZ,
  }) {
    var n = 0;
    for (var z = minZ; z <= maxZ; z++) {
      final w = TileMath.lonToX(maxLon, z) - TileMath.lonToX(minLon, z) + 1;
      final h = TileMath.latToY(minLat, z) - TileMath.latToY(maxLat, z) + 1;
      n += w * h;
    }
    return n;
  }
}
