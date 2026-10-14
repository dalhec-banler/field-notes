part of '../map_screen.dart';

/// The data layers: loading the layer set, turning each layer into the
/// GeoJSON its source wants, and the watch that keeps them current.
mixin _MapScreenRecords on _MapScreenClusters {
  /// The layer set for this place, narrowed by the ledger's filter — the
  /// one filter the ledger writes and the map reads (D-024).
  Future<MapLayerSet> _loadLayers(Property property) => _scope.mapLayers.load(
    property,
    filter: _scope.recordFilter.query,
  );

  /// Reload the layer set and push what changed. Fires on any change to
  /// the tables the layers read, on a filter change, and on coming back
  /// to the map — a record saved five minutes from now has to appear
  /// without restarting the app.
  Future<void> _refreshLayers() async {
    final db = widget.db;
    final property = widget.property;
    final controller = _controller;
    if (db == null || property == null || controller == null) return;
    if (!_recordLayersReady && !_featureLayerReady && !_photoPointLayerReady) {
      return;
    }
    final seq = ++_layerSeq;
    try {
      final set = await _loadLayers(property);
      if (seq != _layerSeq) return; // a newer load answers instead
      _layers = set;
      await _applyLayerSet(set);
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._refreshLayers');
      // A redraw failure must never take the map down.
    }
  }

  /// Keep the data layers in step with the ledger: any change to a table
  /// a layer reads redraws from a fresh set.
  void _watchLayers() {
    if (widget.db == null) return;
    _layerSub?.cancel();
    _layerSub = _scope.mapLayers.changes.listen((_) => _refreshLayers());
  }

  /// For each layer in the set, the source it feeds. Zones, the boundary
  /// and the tracks were put on the style when it loaded; the imagery is
  /// the style's own raster; the clusters are cut per zoom by
  /// [_paintRecords]; the fix has its own source fed by the hub.
  Future<void> _applyLayerSet(MapLayerSet set) async {
    final controller = _controller;
    if (controller == null) return;
    for (final layer in set.layers) {
      switch (layer) {
        case FeatureMarks(:final features) when _featureLayerReady:
          try {
            await controller.setGeoJsonSource(
              'features',
              _featureCollection(features),
            );
          } catch (e, st) {
            Diag.report(e, st, where: 'MapScreen._refreshFeatures');
          }
        case PhotoPointStations(:final stations) when _photoPointLayerReady:
          try {
            await controller.setGeoJsonSource(
              'photopoints',
              _photoPointCollection(stations),
            );
          } catch (e, st) {
            Diag.report(e, st, where: 'MapScreen._refreshPhotoPoints');
          }
        case RecordMarks(:final records) when _recordLayersReady:
          _records = records;
          await _paintRecords();
          widget.onRecordCount?.call(records.length);
        case ImageryBase():
        case ZoneFills():
        case BoundaryLine():
        case TrackLines():
        case RecordClusters():
        case PositionMark():
          break;
        case ProtocolSiteMarks():
          // Not drawn on the phone.
          break;
        case FeatureMarks():
        case PhotoPointStations():
        case RecordMarks():
          // The style has no layer for it yet; the style load pushes it.
          break;
      }
    }
  }

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
}

// ── layer → GeoJSON, the phone's own encoding ──────────────────────

/// One record as the 'observations' source wants it. `kind` is what the
/// pin is coloured and sized by: growth form when the record names a
/// plant, otherwise the record type (record_ink.kindColorMatch).
Map<String, dynamic> _recordFeature(MapRecord r) => {
  'type': 'Feature',
  'geometry': {
    'type': 'Point',
    'coordinates': [r.lng, r.lat],
  },
  'properties': {
    'id': r.id,
    'type': r.type,
    'kind': r.kind,
    'growth': r.growthForm ?? '',
    'named': r.label != null,
    'species': r.label ?? '',
    'removal': r.removal ?? '',
  },
};

/// Every live feature, coloured and iconed by class. A feature whose
/// geometry will not parse is skipped, and said so.
Map<String, dynamic> _featureCollection(List<FeatureMark> features) {
  final out = <Map<String, dynamic>>[];
  for (final f in features) {
    Map<String, dynamic> geometry;
    try {
      geometry = jsonDecode(f.geojson) as Map<String, dynamic>;
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._featureCollection');
      continue;
    }
    out.add({
      'type': 'Feature',
      'geometry': geometry,
      'properties': {
        'fid': f.id,
        'name': f.name,
        'cls': f.featureClass,
        'icon': 'feature-${f.featureClass}',
        'color': cssHex(f.ink),
      },
    });
  }
  return {'type': 'FeatureCollection', 'features': out};
}

/// Every photo point: the station, its view wedge, and its axis. A point
/// never captured draws as a station only — it doesn't claim to look
/// anywhere.
Map<String, dynamic> _photoPointCollection(List<PhotoStation> stations) {
  final out = <Map<String, dynamic>>[];
  for (final p in stations) {
    out.add({
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [p.lng, p.lat],
      },
      'properties': {'ppid': p.id, 'name': p.name},
    });
    if (!p.hasView) continue;
    out.add({
      'type': 'Feature',
      'geometry': {
        'type': 'Polygon',
        'coordinates': [p.wedge],
      },
      'properties': {'ppid': p.id},
    });
    out.add({
      'type': 'Feature',
      'geometry': {'type': 'LineString', 'coordinates': p.axis},
      'properties': {'ppid': p.id},
    });
  }
  return {'type': 'FeatureCollection', 'features': out};
}

/// The fix and its accuracy ring for the 'me' source.
Map<String, dynamic> _positionCollection(PositionMark me) => {
  'type': 'FeatureCollection',
  'features': [
    if (me.hasRing)
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Polygon',
          'coordinates': [me.ring()],
        },
        'properties': {'acc': me.accuracyM},
      },
    {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [me.lng, me.lat],
      },
      'properties': {'acc': me.accuracyM},
    },
  ],
};
