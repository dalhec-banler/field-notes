part of '../map_screen.dart';

mixin _MapScreenClusters on _MapScreenCore {
  /// Regroup the pins for the current zoom and push them to the source.
  /// Runs on every camera idle and after every data refresh; a paint that
  /// arrives mid-paint queues one more, never a pile.
  Future<void> _paintRecords() async {
    final controller = _controller;
    if (controller == null || !_recordLayersReady) return;
    if (_painting) {
      _paintAgain = true;
      return;
    }
    _painting = true;
    // A platform call that never answers (the map covered by the camera,
    // the app asleep in a pocket) would otherwise hold _painting forever,
    // and every record saved after it would queue behind it until a
    // restart (Austin, 2026-09-07: "they don't pop up until I re-open").
    Future<T> bounded<T>(Future<T> call) =>
        call.timeout(const Duration(seconds: 8));
    try {
      final zoom = controller.cameraPosition?.zoom ?? 15;
      // Clustering depends only on zoom and the feature list: a pan-only
      // idle would re-push byte-identical sources over the channel.
      if (zoom == _lastPaintZoom && identical(_recordFeatures, _lastPainted)) {
        return;
      }
      final groups = clusterFeatures(_recordFeatures, zoom);
      final singles = <Map<String, dynamic>>[];
      final out = <Map<String, dynamic>>[];
      final index = <String, ClusterGroup>{};
      for (final g in groups) {
        if (!g.isCluster) {
          singles.add(g.members.single);
          continue;
        }
        final n = g.members.length;
        final icon = clusterIconKey(n);
        if (!_badgeImages.contains(icon)) {
          await bounded(controller.addImage(icon, await clusterBadge(n)));
          _badgeImages.add(icon);
        }
        final (lat, lng) = g.centre;
        // Content-derived id: stable across repaints while membership holds
        // (same-process only, which is all a tap lookup needs).
        final id = 'cluster:${g.ids.join(',').hashCode}';
        index[id] = g;
        out.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [lng, lat],
          },
          'properties': {'id': id, 'cluster': true, 'count': n, 'icon': icon},
        });
      }
      await bounded(
        controller.setGeoJsonSource('observations', {
          'type': 'FeatureCollection',
          'features': singles,
        }),
      );
      await bounded(
        controller.setGeoJsonSource('obs-clusters', {
          'type': 'FeatureCollection',
          'features': out,
        }),
      );
      _clusterIndex
        ..clear()
        ..addAll(index);
      _lastPaintZoom = zoom;
      _lastPainted = _recordFeatures;
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._paintRecords');
      // A repaint failure must never take the map down.
    } finally {
      _painting = false;
      if (_paintAgain) {
        _paintAgain = false;
        _paintRecords();
      }
    }
  }
}
