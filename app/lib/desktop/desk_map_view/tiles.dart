part of '../desk_map_view.dart';

/// Imagery: the fetcher, camera math, and keeping the visible tiles in
/// memory.
mixin _DeskMapTiles on _DeskMapCore {
  @override
  TileFetcher _buildFetcher() {
    final primary = httpTileFetcher(template: activeImagery.template);
    final chained = activeImagery.id == 'usgs'
        ? primary
        : tileFetcherWithFallback(primary, httpTileFetcher());
    return _tiles.wrap(chained);
  }

  /// Settings can swap the imagery source while this map lives: rebuild
  /// the fetcher, drop every cached tile, and let in-flight fetches from
  /// the old source die on arrival.
  void _syncImagerySource() {
    if (_fetchSourceId == activeImagery.id) return;
    _fetchSourceId = activeImagery.id;
    _tileEpoch++;
    _fetch = _buildFetcher();
    _tiles.clear();
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _inflight.clear();
    _retryAt.clear();
  }

  (double, double) _worldPx(double lat, double lng) {
    final (x, y) = merc.project(lat, lng, _zInt);
    return (x * _tileScale, y * _tileScale);
  }

  (double, double) _screenOf(double lat, double lng, Size size) {
    final (cx, cy) = _worldPx(_lat!, _lng!);
    final (x, y) = _worldPx(lat, lng);
    return (x - cx + size.width / 2, y - cy + size.height / 2);
  }

  /// Shift what's on screen by [delta] pixels (drag semantics: content
  /// follows the pointer).
  void _panBy(Offset delta, Size size) {
    _userMoved = true;
    final (cx, cy) = _worldPx(_lat!, _lng!);
    final nx = cx - delta.dx;
    final ny = cy - delta.dy;
    final (lat, lng) = merc.unproject(nx / _tileScale, ny / _tileScale, _zInt);
    setState(() {
      _lat = lat.clamp(-84.0, 84.0);
      _lng = lng;
    });
  }

  void _zoomBy(double dz, Offset about, Size size) {
    _userMoved = true;
    // Anchor the zoom on the CURSOR: the coordinate under it must stay
    // under it. The first cut re-centred that point to the window middle,
    // so successive scrolls dragged the camera across town (Austin,
    // 2026-09-03).
    final aLatLng = _latLngAt(about, size);
    setState(() {
      _zoom = (_zoom + dz).clamp(4.0, activeImagery.maxZoom + 0.99);
    });
    final (ax, ay) = _screenOf(aLatLng.$1, aLatLng.$2, size);
    _panBy(Offset(about.dx - ax, about.dy - ay), size);
  }

  (double, double) _latLngAt(Offset p, Size size) {
    final (cx, cy) = _worldPx(_lat!, _lng!);
    final wx = cx + (p.dx - size.width / 2);
    final wy = cy + (p.dy - size.height / 2);
    return merc.unproject(wx / _tileScale, wy / _tileScale, _zInt);
  }

  // ── tiles ────────────────────────────────────────────────────────

  void _ensureVisibleTiles(Size size) {
    final z = _zInt;
    final n = 1 << z;
    final (cx, cy) = _worldPx(_lat!, _lng!);
    final drawn = merc.tileSize * _tileScale;
    final left = ((cx - size.width / 2) / drawn).floor();
    final top = ((cy - size.height / 2) / drawn).floor();
    final right = ((cx + size.width / 2) / drawn).floor();
    final bottom = ((cy + size.height / 2) / drawn).floor();
    for (var ty = top; ty <= bottom; ty++) {
      for (var tx = left; tx <= right; tx++) {
        if (tx < 0 || ty < 0 || tx >= n || ty >= n) continue;
        final key = '$z/$tx/$ty';
        final retryAt = _retryAt[key];
        if (_images.containsKey(key) ||
            _inflight.contains(key) ||
            (retryAt != null && DateTime.now().isBefore(retryAt))) {
          continue;
        }
        _retryAt.remove(key);
        _inflight.add(key);
        final epoch = _tileEpoch;
        void miss() => _retryAt[key] = DateTime.now().add(_retryAfter);
        _fetch(z, tx, ty).then((bytes) async {
          if (epoch != _tileEpoch) return; // source swapped mid-flight
          _inflight.remove(key);
          if (bytes == null) {
            miss();
            return;
          }
          try {
            final codec = await ui.instantiateImageCodec(bytes);
            final img = (await codec.getNextFrame()).image;
            codec.dispose();
            if (!mounted || epoch != _tileEpoch) {
              img.dispose();
              return;
            }
            setState(() => _images[key] = img);
          } catch (e, st) {
            Diag.report(e, st, where: 'DeskMapWorkspace._ensureVisibleTiles');
            miss();
          }
        });
      }
    }
  }
}
