part of '../map_screen.dart';

/// What the data layers draw from: records, photo points and features,
/// and the watches that keep them current.
mixin _MapScreenRecords on _MapScreenClusters {
  /// Every photo point on this property: the station, its view wedge, and
  /// its axis. A point with no bearing yet (never captured) draws as a
  /// station only — it doesn't claim to look anywhere.
  Future<void> _refreshPhotoPoints() async {
    final db = widget.db;
    final property = widget.property;
    final controller = _controller;
    if (db == null || property == null || controller == null) return;
    if (!_photoPointLayerReady) return;
    try {
      final points = await _scope.photoPoints.on(property.id);
      final out = <Map<String, dynamic>>[];
      for (final p in points) {
        out.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [p.lng, p.lat],
          },
          'properties': {'ppid': p.id, 'name': p.name},
        });
        if (p.bearingDeg == 0 && p.referenceMediaId == null) continue;
        final extent = p.viewExtentM ?? 60;
        out.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              viewWedge(
                lat: p.lat,
                lng: p.lng,
                bearingDeg: p.bearingDeg,
                focalLengthMm: p.focalLengthMm,
                extentM: extent,
              ),
            ],
          },
          'properties': {'ppid': p.id},
        });
        out.add({
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': viewAxis(
              lat: p.lat,
              lng: p.lng,
              bearingDeg: p.bearingDeg,
              extentM: extent,
            ),
          },
          'properties': {'ppid': p.id},
        });
      }
      await controller.setGeoJsonSource('photopoints', {
        'type': 'FeatureCollection',
        'features': out,
      });
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._refreshPhotoPoints');
    }
  }

  /// Every live feature on this property, coloured and iconed by class.
  Future<void> _refreshFeatures() async {
    final db = widget.db;
    final property = widget.property;
    final controller = _controller;
    if (db == null || property == null || controller == null) return;
    if (!_featureLayerReady) return;
    try {
      final rows = await db
          .customSelect(
            'SELECT f.id AS id, f.name AS name, f.geojson AS geojson, '
            't.feature_class AS cls, t.label AS label '
            'FROM features f JOIN feature_types t ON t.id = f.feature_type_id '
            'WHERE f.property_id = ? AND f.deleted_at IS NULL',
            variables: [Variable.withString(property.id)],
            readsFrom: {db.features, db.featureTypes},
          )
          .get();
      final out = <Map<String, dynamic>>[];
      for (final r in rows) {
        final cls = r.data['cls'] as String? ?? 'natural';
        Map<String, dynamic> geometry;
        try {
          geometry =
              jsonDecode(r.data['geojson'] as String) as Map<String, dynamic>;
        } catch (e, st) {
          Diag.report(e, st, where: 'MapScreen._refreshFeatures');
          continue;
        }
        out.add({
          'type': 'Feature',
          'geometry': geometry,
          'properties': {
            'fid': r.data['id'],
            'name': r.data['name'] ?? r.data['label'],
            'cls': cls,
            'icon': 'feature-$cls',
            'color': switch (cls) {
              'problem' => '#8B2E22',
              'infrastructure' => '#1B1813',
              _ => '#2F5D8A',
            },
          },
        });
      }
      await controller.setGeoJsonSource('features', {
        'type': 'FeatureCollection',
        'features': out,
      });
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._refreshFeatures');
    }
  }

  /// Keep the pins in step with the ledger: any insert, edit or delete of an
  /// observation (or of the species library behind it) redraws the source.
  void _watchRecords() {
    final db = widget.db;
    if (db == null) return;
    _recordSub?.cancel();
    _recordSub = _scope.observations.pinChanges.listen(
      (_) => _refreshRecords(),
    );
  }

  /// the pin is drawn from.
  /// A property with no boundary yet, and records spread across it, should
  /// open showing all of them. initialCameraPosition can't express bounds,
  /// so the framing happens once the map is up.
  Future<void> _frameRecordsIfNeeded() async {
    final bounds = _recordBounds;
    final controller = _controller;
    if (bounds == null || controller == null || _framedRecords) return;
    if (_openedOnFix && (_presence?.onSite ?? false)) return;
    if (widget.property != null && propertyCentre(widget.property!) != null) {
      return; // the property knows its own place; leave the camera there
    }
    _framedRecords = true;
    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(bounds[1], bounds[0]),
            northeast: LatLng(bounds[3], bounds[2]),
          ),
          left: 48,
          right: 48,
          top: 150,
          bottom: 160,
        ),
      );
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._frameRecordsIfNeeded');
    }
  }

  /// Mean of located records — a stand-in centre for a property with no
  /// boundary yet, so the map opens on the work instead of nowhere.
  Future<void> _loadRecordCentre() async {
    final db = widget.db;
    final property = widget.property;
    if (db == null || property == null) return;
    if (propertyCentre(property) != null) return;
    try {
      final extent = await _scope.observations.locatedExtent(property.id);
      final n = extent.count;
      final lat = extent.meanLat;
      final lng = extent.meanLng;
      if (n > 0 && lat != null && lng != null) {
        _recordCentre = [lng, lat];
        final minLat = extent.minLat;
        final maxLat = extent.maxLat;
        final minLng = extent.minLng;
        final maxLng = extent.maxLng;
        if (n > 1 &&
            minLat != null &&
            maxLat != null &&
            minLng != null &&
            maxLng != null &&
            (maxLat - minLat > 0.0002 || maxLng - minLng > 0.0002)) {
          _recordBounds = [minLng, minLat, maxLng, maxLat];
        }
      }
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._loadRecordCentre');
    }
  }

  Future<void> _refreshRecords() async {
    final db = widget.db;
    final property = widget.property;
    final controller = _controller;
    if (db == null || property == null || controller == null) return;
    if (!_recordLayersReady) return;
    try {
      final rows = await _scope.observations.pins(property.id);
      // The ledger is the filter: the map draws exactly what it lists.
      final flt = _scope.recordFilter;
      final bounds = flt.utcDayBounds;
      final features = <Map<String, dynamic>>[];
      for (final r in rows) {
        final growth = r.growthForm;
        final type = r.type;
        final species = r.species;
        if (flt.type != null && type != flt.type) continue;
        if (flt.flagged && r.removalStatus != 'flagged') continue;
        if (flt.taxonId != null && r.taxonId != flt.taxonId) continue;
        if (flt.zoneId != null && r.zoneId != flt.zoneId) continue;
        if (bounds != null) {
          final at = r.observedAt;
          if (at.compareTo(bounds.$1) < 0 || at.compareTo(bounds.$2) >= 0) {
            continue;
          }
        }
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [r.lng, r.lat],
          },
          'properties': {
            'id': r.id,
            'type': type,
            // What the pin is coloured by: growth form when the record
            // names a plant, otherwise the record type.
            'kind': growth ?? type,
            'growth': growth ?? '',
            'named': species != null,
            'species': species ?? '',
            'removal': r.removalStatus ?? '',
          },
        });
      }
      _recordFeatures = features;
      await _paintRecords();
      widget.onRecordCount?.call(features.length);
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._refreshRecords');
      // A redraw failure must never take the map down.
    }
  }
}
