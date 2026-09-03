import 'dart:collection';
import 'dart:typed_data';

import '../export/map_plate.dart' show TileFetcher;

/// Session-scoped imagery tile cache. The export workspace re-renders the
/// plate on every layer toggle and the desk map repaints on every pan —
/// neither changes which pixels a tile holds, so fetching them twice is
/// pure wait (the export audit's finding 8).
class TileCache {
  TileCache({this.capacity = 600});

  final int capacity;
  final _lru = LinkedHashMap<String, Uint8List>();

  /// Wrap [inner] so hits skip the network. Only successful fetches are
  /// cached; a miss (offline moment, missing tile) stays retryable.
  TileFetcher wrap(TileFetcher inner) => (z, x, y) async {
    final key = '$z/$x/$y';
    final hit = _lru.remove(key);
    if (hit != null) {
      _lru[key] = hit; // back to most-recent
      return hit;
    }
    final bytes = await inner(z, x, y);
    if (bytes != null) {
      _lru[key] = bytes;
      if (_lru.length > capacity) _lru.remove(_lru.keys.first);
    }
    return bytes;
  };

  void clear() => _lru.clear();
}

/// A fetcher that tries [primary] and, when it comes back empty at a zoom
/// the [fallback] still covers, asks the fallback — so a sharper source
/// with patchy coverage never leaves paper holes USGS could have filled.
TileFetcher tileFetcherWithFallback(
  TileFetcher primary,
  TileFetcher fallback, {
  int fallbackMaxZoom = 16,
}) =>
    (z, x, y) async =>
        await primary(z, x, y) ??
        (z <= fallbackMaxZoom ? await fallback(z, x, y) : null);
