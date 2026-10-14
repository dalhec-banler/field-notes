part of '../map_tab.dart';

/// The map tab's state: controller, focus and jump requests, coverage,
/// counts, presence and the layer toggles.
mixin _MapTabCore on State<MapTab> {
  late final AppScope _scope = AppScope.of(context);
  ObservationsRepo get _records => _scope.observations;
  ZonesRepo get _zones => _scope.zones;
  PhotoPointsRepo get _photoPoints => _scope.photoPoints;

  int _zoneCount = 0;
  MapLibreMapController? _controller;

  LatLng? _pendingFocus;

  void _onFocusRequest() {
    final v = widget.focus?.value;
    if (v == null) return;
    widget.focus?.value = null;
    _pendingFocus = v;
    _consumeFocus();
  }

  void _consumeFocus() {
    final v = _pendingFocus;
    final c = _controller;
    if (v == null || c == null) return;
    _pendingFocus = null;
    c.animateCamera(CameraUpdate.newLatLngZoom(v, 17));
  }

  /// A jump for this place (D-029) is taken as soon as a controller can:
  /// on the notifier firing when the map is already up, or on the new
  /// controller after the shell switched place to get here.
  void _onMapJump() {
    final j = _scope.mapJump.value;
    final c = _controller;
    if (j == null || c == null || j.propertyId != widget.property.id) return;
    _scope.mapJump.value = null;
    c.animateCamera(CameraUpdate.newLatLngZoom(LatLng(j.lat, j.lng), 17.5));
  }

  bool _captureMode = false;
  final _downloader = AreaDownloader();
  int _mapEpoch = 0; // bump to rebuild the map after a capture

  /// Offline basemap bounds `[minLon, minLat, maxLon, maxLat]`, or null if
  /// unknown.
  List<double>? _coverage;

  bool _covered(Position fix) {
    final b = _coverage;
    if (b == null) return true; // unknown → don't nag
    return fix.longitude >= b[0] &&
        fix.longitude <= b[2] &&
        fix.latitude >= b[1] &&
        fix.latitude <= b[3];
  }

  // Layer toggles (spec §7.1): record types, zones, tracks. Kept on the tab
  // so they survive the map being re-keyed after a capture.

  /// What a plant is, as the library records it. Filtering by this is the
  /// point of the map for a planting: where are the trees, where's the grass.

  /// Records to draw: how many are on the map right now.
  int _recordCount = 0;

  /// Where the phone is relative to this place.
  SitePresence _presence = SitePresence.unknown;
  bool _showZones = true;
  bool _showTracks = true;
  bool _showFeatures = true;
  bool _showPhotoPoints = true;

  /// Satellite imagery draws over the offline vector map. The standard view
  /// (on by default, remembered): imagery is what the ground actually looks
  /// like, and it covers everywhere there's signal — including the gaps an
  /// offline extract doesn't reach, which used to read as "the map didn't
  /// load". Offline with no signal, the raster tiles simply don't draw and
  /// the vector map underneath carries on.
  late bool _showSatellite = widget.prefs.mapSatellite;
  bool get _layersTouched =>
      !_showZones || !_showTracks || !_showFeatures || !_showSatellite;

  /// The sheet's toggles as the layer model states them (D-038 item 11):
  /// imagery is the satellite raster; records and the boundary are never
  /// switched off on the phone.
  LayerVisibility get _visibility => LayerVisibility(
    imagery: _showSatellite,
    zones: _showZones,
    tracks: _showTracks,
    features: _showFeatures,
    photoPoints: _showPhotoPoints,
  );
}
