part of '../map_screen.dart';

/// The live fix: watching it, deciding the opening camera, and the
/// position feature with its accuracy ring.
mixin _MapScreenPosition on _MapScreenRecords {
  bool _watching = false;

  void _watchPosition() async {
    if (_watching || _fixSub != null) return;
    _watching = true;
    try {
      if (!await _scope.locationHub.ensurePermission()) return;
      if (!mounted || !(widget.visible && _inForeground)) return;
      final last = _scope.locationHub.last;
      if (last != null) _onFix(last);
      _fixSub = _scope.locationHub.positions.listen(_onFix);
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._watchPosition');
    } finally {
      _watching = false;
    }
  }

  /// Standing on the place → open where you are. Somewhere else → open on
  /// the place; dragging the map 90 miles into town helps nobody. Knowing
  /// neither → open on the fix, and let the first fix recentre.
  CameraPosition _decideCamera() {
    final fresh = _scope.locationHub.fresh() ?? _fix;
    final property = widget.property;
    final presence = property == null
        ? SitePresence.unknown
        : presenceFor(property, fresh?.latitude, fresh?.longitude);
    final centre = property == null ? null : _centreFor(property);

    if (fresh != null && (presence.onSite || centre == null)) {
      _openedOnFix = true;
      return CameraPosition(
        target: LatLng(fresh.latitude, fresh.longitude),
        zoom: 16,
      );
    }
    if (centre != null) {
      // Off site: the place is the subject, and a later fix must not yank
      // the camera away from it.
      _openedOnFix = true;
      return CameraPosition(
        target: LatLng(centre[1], centre[0]),
        zoom: property?.boundaryGeojson != null ? 14 : 15,
      );
    }
    // Nothing known yet — no fix, no boundary, no records. Sit at a wide
    // view and let the first fix bring us somewhere real.
    _openedOnFix = false;
    return const CameraPosition(target: LatLng(39.5, -98.35), zoom: 3);
  }

  /// The property's own centre, or — for a place that has never had a
  /// boundary imported — the middle of the records already made on it.
  /// A place with fifty records in it knows perfectly well where it is.
  List<double>? _centreFor(Property property) =>
      propertyCentre(property) ?? _recordCentre;

  Future<void> _onFix(Position pos) async {
    _fix = pos;
    final property = widget.property;
    if (property != null) {
      final presence = presenceFor(property, pos.latitude, pos.longitude);
      if (presence.onSite != _presence?.onSite ||
          _presence == null ||
          ((presence.distanceM ?? 0) - (_presence!.distanceM ?? 0)).abs() >
              50) {
        _presence = presence;
        widget.onPresence?.call(presence);
      }
    }
    final controller = _controller;
    if (controller == null) return;
    if (!_openedOnFix && widget.visible) {
      _openedOnFix = true;
      try {
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 16),
        );
      } catch (e, st) {
        Diag.report(e, st, where: 'MapScreen._onFix');
      }
    }
    if (!_positionLayerReady) return;
    try {
      await controller.setGeoJsonSource('me', _positionGeoJson(pos));
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._onFix');
    }
  }

  Map<String, dynamic> _positionGeoJson(Position pos) {
    final acc = pos.accuracy;
    return {
      'type': 'FeatureCollection',
      'features': [
        if (acc.isFinite && acc > 1)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Polygon',
              'coordinates': [_accuracyRing(pos.latitude, pos.longitude, acc)],
            },
            'properties': {'acc': acc},
          },
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [pos.longitude, pos.latitude],
          },
          'properties': {'acc': acc},
        },
      ],
    };
  }

  /// The accuracy circle as ground coordinates, so it scales with the map
  /// instead of pretending to be a fixed number of pixels.
  static List<List<double>> _accuracyRing(
    double lat,
    double lng,
    double metres, {
    int steps = 36,
  }) {
    final dLat = metres / 111320.0;
    final dLng =
        metres / (111320.0 * mathlib.cos(lat * mathlib.pi / 180).abs());
    return [
      for (var i = 0; i <= steps; i++)
        [
          lng + dLng * mathlib.sin(2 * mathlib.pi * i / steps),
          lat + dLat * mathlib.cos(2 * mathlib.pi * i / steps),
        ],
    ];
  }
}
