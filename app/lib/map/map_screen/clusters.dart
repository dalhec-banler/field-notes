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
      // Clustering depends only on zoom and the record list: a pan-only
      // idle would re-push byte-identical sources over the channel.
      if (zoom == _lastPaintZoom && identical(_records, _lastPainted)) {
        return;
      }
      // The clusters layer, derived from the records layer at this zoom —
      // the same cells the desk badges (record_clusters.dart).
      final clusters = RecordClusters.at(_records, zoom);
      final singles = <Map<String, dynamic>>[];
      final out = <Map<String, dynamic>>[];
      final index = <String, RecordCell>{};
      for (final cell in clusters.cells) {
        if (!cell.isCluster) {
          singles.add(_recordFeature(cell.members.single));
          continue;
        }
        final n = cell.members.length;
        final icon = clusterIconKey(n);
        if (!_badgeImages.contains(icon)) {
          await bounded(controller.addImage(icon, await clusterBadge(n)));
          _badgeImages.add(icon);
        }
        final (lat, lng) = cell.centre;
        // Content-derived id: stable across repaints while membership holds
        // (same-process only, which is all a tap lookup needs).
        final id = 'cluster:${cell.ids.join(',').hashCode}';
        index[id] = cell;
        out.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [lng, lat],
          },
          'properties': {'id': id, 'cluster': true, 'count': n, 'icon': icon},
        });
      }
      // Two sources on purpose (DESIGN.md): singles on 'observations' so
      // the circle / shape / removal layers can style them; badges on
      // 'obs-clusters' as pre-drawn images.
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
      _lastPainted = _records;
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
