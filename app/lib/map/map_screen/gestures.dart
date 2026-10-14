part of '../map_screen.dart';

/// Taps and long-presses, resolved against the rendered features.
mixin _MapScreenGestures on _MapScreenLayers {
  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
    // Pin tap → the record. The plugin hands us the screen point; ask the
    // renderer what's under it so we get the feature's properties back.
    controller.onFeatureTapped.add((point, latLng, id, layerId, _) async {
      final hit = await _hitAt(point);
      if (hit == null) {
        final ppid = await _photoPointAt(point);
        if (ppid != null) {
          widget.onPhotoPointTap?.call(ppid);
          return;
        }
        final fid = await _featureAt(point);
        if (fid != null) widget.onFeatureTap?.call(fid);
        return;
      }
      if (!hit.isCluster) {
        widget.onRecordTap?.call(hit.ids.single);
        return;
      }
      // The Zillow move: land where the cluster splits; if it never does,
      // the sheet lists what's here.
      final zoom = controller.cameraPosition?.zoom ?? 15;
      final z = expansionZoomBy(hit.members, recordCoords, zoom);
      if (z != null) {
        final (lat, lng) = hit.centre;
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(lat, lng), z),
        );
      } else {
        widget.onClusterTap?.call(hit.ids);
      }
    });
    widget.onController?.call(controller);
  }

  Future<String?> _featureAt(Point<double> point) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final hits = await controller.queryRenderedFeatures(point, [
        'features-pt',
      ], null);
      for (final h in hits) {
        final fid = ((h as Map)['properties'] as Map?)?['fid'] as String?;
        if (fid != null) return fid;
      }
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._featureAt');
    }
    return null;
  }

  /// What is under a screen point: a single record or a cluster, or null.
  Future<RecordCell?> _hitAt(Point<double> point) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final hits = await controller.queryRenderedFeatures(point, [
        'obs-clusters-lyr',
        'observations-circles',
        'observations-shapes',
      ], null);
      for (final h in hits) {
        final props = (h as Map)['properties'] as Map?;
        final id = props?['id'] as String?;
        if (id == null) continue;
        // Clusters resolve through the index the last paint built — no
        // member lists round-tripping through GeoJSON properties as CSV.
        final cluster = _clusterIndex[id];
        if (cluster != null) return cluster;
        final r = _records.where((r) => r.id == id).firstOrNull;
        if (r != null) return RecordCell([r]);
      }
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._hitAt');
    }
    return null;
  }

  /// Long-press on a dot or cluster always opens the sheet; on bare map it
  /// keeps meaning "capture here".
  Future<void> _onLongClick(Point<double> point, LatLng latLng) async {
    final hit = await _hitAt(point);
    if (hit != null && widget.onClusterTap != null) {
      widget.onClusterTap!(hit.ids);
      return;
    }
    widget.onLongPress?.call(latLng);
  }

  Future<String?> _photoPointAt(Point<double> point) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final hits = await controller.queryRenderedFeatures(point, [
        'pp-pt',
      ], null);
      for (final h in hits) {
        final id = ((h as Map)['properties'] as Map?)?['ppid'] as String?;
        if (id != null) return id;
      }
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._photoPointAt');
    }
    return null;
  }
}
