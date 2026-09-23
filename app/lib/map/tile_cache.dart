import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

/// Decoded-image cache: the layer above [TileCache].
///
/// [TileCache] spares the network but not the CPU — the plate re-ran
/// `instantiateImageCodec` on every tile of every render and disposed the
/// result immediately, so toggling one checkbox re-decoded the whole sheet
/// (~150 tiles on a poster). Worse, an overzoomed frame asks for the same
/// parent tile once per quadrant: at depth 2 that is sixteen decodes of one
/// image. Keying on the SOURCE tile collapses both — the quadrants share
/// one decode, and the next render finds it already decoded.
///
/// Entries touched in the current generation are pinned: a render that
/// needs more tiles than [capacity] must not have its own images disposed
/// out from under it between the fetch pass and the draw pass.
class DecodedImageCache {
  DecodedImageCache({this.capacity = 320});

  final int capacity;
  final _lru = LinkedHashMap<String, ui.Image>();
  final _inflight = <String, Future<ui.Image?>>{};
  final _pinned = <String>{};

  /// Start of a render: nothing is pinned until this render asks for it.
  void beginGeneration() => _pinned.clear();

  /// The decoded image for [key], decoding [bytes] only on a miss. Two
  /// workers asking for the same parent tile at once share one decode.
  Future<ui.Image?> get(String key, Future<Uint8List?> Function() bytes) {
    final hit = _lru.remove(key);
    if (hit != null) {
      _lru[key] = hit; // back to most-recent
      _pinned.add(key);
      return Future.value(hit);
    }
    return _inflight[key] ??= _decode(key, bytes);
  }

  Future<ui.Image?> _decode(
    String key,
    Future<Uint8List?> Function() bytes,
  ) async {
    try {
      final b = await bytes();
      if (b == null) return null;
      final codec = await ui.instantiateImageCodec(b);
      final img = (await codec.getNextFrame()).image;
      codec.dispose();
      _lru[key] = img;
      _pinned.add(key);
      _evict();
      return img;
    } catch (_) {
      return null;
    } finally {
      _inflight.remove(key);
    }
  }

  /// Evict the oldest UNPINNED entry. When everything in the cache belongs
  /// to the render in flight, the cache is allowed over capacity until the
  /// next generation — a disposed image mid-draw is a crash, a briefly
  /// large cache is not.
  void _evict() {
    while (_lru.length > capacity) {
      String? victim;
      for (final k in _lru.keys) {
        if (!_pinned.contains(k)) {
          victim = k;
          break;
        }
      }
      if (victim == null) return;
      _lru.remove(victim)!.dispose();
    }
  }

  void clear() {
    for (final img in _lru.values) {
      img.dispose();
    }
    _lru.clear();
    _pinned.clear();
  }
}
