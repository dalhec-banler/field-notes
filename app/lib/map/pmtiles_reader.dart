import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

/// Minimal PMTiles v3 *reader* over range requests (spec §3.4 knowledge:
/// PMTiles is a single-file archive addressed by byte ranges). Enough to
/// pull individual tiles out of a remote planet archive for area download —
/// no writer needed because downloaded areas are stored as MBTiles.
abstract class RangeSource {
  Future<Uint8List> read(int offset, int length);
  void close() {}
}

class FileRangeSource implements RangeSource {
  FileRangeSource(this.file) : _raf = file.openSync();
  final File file;
  final RandomAccessFile _raf;

  @override
  Future<Uint8List> read(int offset, int length) async {
    _raf.setPositionSync(offset);
    return _raf.readSync(length);
  }

  @override
  void close() => _raf.closeSync();
}

class HttpRangeSource implements RangeSource {
  HttpRangeSource(this.url, {http.Client? client})
      : _client = client ?? http.Client();
  final String url;
  final http.Client _client;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final res = await _client.get(
      Uri.parse(url),
      headers: {'Range': 'bytes=$offset-${offset + length - 1}'},
    );
    if (res.statusCode != 206 && res.statusCode != 200) {
      throw http.ClientException('range read failed: HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  @override
  void close() => _client.close();
}

class PmTilesHeader {
  PmTilesHeader({
    required this.rootDirOffset,
    required this.rootDirLength,
    required this.leafDirsOffset,
    required this.tileDataOffset,
    required this.internalCompression,
    required this.tileCompression,
    required this.minZoom,
    required this.maxZoom,
    required this.bounds, // [minLon, minLat, maxLon, maxLat]
  });

  final int rootDirOffset;
  final int rootDirLength;
  final int leafDirsOffset;
  final int tileDataOffset;
  final int internalCompression; // 1 none · 2 gzip
  final int tileCompression;
  final int minZoom;
  final int maxZoom;
  final List<double> bounds;
}

class _Entry {
  _Entry(this.tileId, this.offset, this.length, this.runLength);
  final int tileId;
  final int offset;
  final int length;
  final int runLength; // 0 = leaf directory pointer
}

class PmTilesReader {
  PmTilesReader._(this._source, this.header);

  final RangeSource _source;
  final PmTilesHeader header;
  List<_Entry>? _rootDir;
  final Map<int, List<_Entry>> _leafCache = {};

  static Future<PmTilesReader> open(RangeSource source) async {
    final h = await source.read(0, 127);
    if (String.fromCharCodes(h.sublist(0, 7)) != 'PMTiles' || h[7] != 3) {
      throw const FormatException('not a PMTiles v3 archive');
    }
    final bd = ByteData.sublistView(h);
    int u64(int off) => bd.getUint64(off, Endian.little);
    int i32(int off) => bd.getInt32(off, Endian.little);
    final header = PmTilesHeader(
      rootDirOffset: u64(8),
      rootDirLength: u64(16),
      leafDirsOffset: u64(40),
      tileDataOffset: u64(56),
      internalCompression: h[97],
      tileCompression: h[98],
      minZoom: h[100],
      maxZoom: h[101],
      bounds: [
        i32(102) / 1e7,
        i32(106) / 1e7,
        i32(110) / 1e7,
        i32(114) / 1e7,
      ],
    );
    return PmTilesReader._(source, header);
  }

  void close() => _source.close();

  /// Raw stored bytes for tile z/x/y (still tile-compressed — typically
  /// gzip'd MVT), or null when the archive has no such tile.
  Future<Uint8List?> getTile(int z, int x, int y) async {
    final target = zxyToTileId(z, x, y);
    _rootDir ??= _parseDirectory(await _inflate(
        await _source.read(header.rootDirOffset, header.rootDirLength)));
    var dir = _rootDir!;
    for (var depth = 0; depth < 4; depth++) {
      final entry = _find(dir, target);
      if (entry == null) return null;
      if (entry.runLength > 0) {
        return _source.read(
            header.tileDataOffset + entry.offset, entry.length);
      }
      // Leaf directory.
      final cached = _leafCache[entry.offset];
      if (cached != null) {
        dir = cached;
      } else {
        dir = _parseDirectory(await _inflate(await _source.read(
            header.leafDirsOffset + entry.offset, entry.length)));
        if (_leafCache.length > 32) _leafCache.clear();
        _leafCache[entry.offset] = dir;
      }
    }
    return null;
  }

  Future<Uint8List> _inflate(Uint8List bytes) async {
    if (header.internalCompression == 2) {
      return Uint8List.fromList(const GZipDecoder().decodeBytes(bytes));
    }
    return bytes;
  }

  _Entry? _find(List<_Entry> dir, int tileId) {
    var lo = 0, hi = dir.length - 1;
    _Entry? best;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (dir[mid].tileId <= tileId) {
        best = dir[mid];
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (best == null) return null;
    if (best.runLength == 0) return best; // descend into leaf
    return tileId < best.tileId + best.runLength ? best : null;
  }

  static List<_Entry> _parseDirectory(Uint8List data) {
    var pos = 0;
    int varint() {
      var shift = 0, result = 0;
      while (true) {
        final b = data[pos++];
        result |= (b & 0x7f) << shift;
        if (b < 0x80) return result;
        shift += 7;
      }
    }

    final n = varint();
    final ids = List<int>.filled(n, 0);
    var last = 0;
    for (var i = 0; i < n; i++) {
      last += varint();
      ids[i] = last;
    }
    final runs = [for (var i = 0; i < n; i++) varint()];
    final lengths = [for (var i = 0; i < n; i++) varint()];
    final offsets = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final v = varint();
      offsets[i] =
          v == 0 ? offsets[i - 1] + lengths[i - 1] : v - 1;
    }
    return [
      for (var i = 0; i < n; i++)
        _Entry(ids[i], offsets[i], lengths[i], runs[i])
    ];
  }
}

/// PMTiles tile id: cumulative count of tiles below zoom z, plus the Hilbert
/// index of (x, y) on the z-order curve.
int zxyToTileId(int z, int x, int y) {
  var acc = 0;
  for (var i = 0; i < z; i++) {
    acc += 1 << (2 * i);
  }
  final n = 1 << z;
  var rx = 0, ry = 0, d = 0;
  var tx = x, ty = y;
  for (var s = n >> 1; s > 0; s >>= 1) {
    rx = (tx & s) > 0 ? 1 : 0;
    ry = (ty & s) > 0 ? 1 : 0;
    d += s * s * ((3 * rx) ^ ry);
    // rotate
    if (ry == 0) {
      if (rx == 1) {
        tx = s - 1 - tx;
        ty = s - 1 - ty;
      }
      final t = tx;
      tx = ty;
      ty = t;
    }
  }
  return acc + d;
}
