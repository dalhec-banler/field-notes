part of '../map_screen.dart';

/// The map screen's state: tile stores, the fix, the camera decision,
/// the controller, the pin/cluster bookkeeping and the layer flags.
const _emptyCollection = {
  'type': 'FeatureCollection',
  'features': <Map<String, dynamic>>[],
};

mixin _MapScreenCore on State<MapScreen> {
  late final AppScope _scope = AppScope.of(context);
  TileServer? _server;
  MbTilesStore? _mbtiles;
  MbTilesStore? _imageryStore;
  String? _styleJson;
  String? _error;
  StreamSubscription<Position>? _fixSub;
  Position? _fix;
  bool _positionLayerReady = false;
  bool _inForeground = true;

  /// True when there is no offline basemap and we're drawing imagery only.
  bool _satelliteOnlyFallback = false;
  bool get satelliteOnlyFallback => _satelliteOnlyFallback;

  /// True once the camera has been centred on the user (at open, or on the
  /// first fix after opening without one). Never re-centres after that —
  /// the map is the user's to pan.
  /// Where the map opened, decided once. Recomputing this per build would
  /// be pointless (MapLibre reads it only at creation) and actively harmful,
  /// because deciding also decides whether the first fix should recentre.
  CameraPosition? _initialCamera;
  bool _openedOnFix = false;
  SitePresence? _presence;

  List<double>? _recordCentre;

  /// `[minLon, minLat, maxLon, maxLat]` of this property's records, when
  /// they're spread widely enough to be worth framing.
  List<double>? _recordBounds;

  /// Whether the record-centre lookup has finished. The camera is decided
  /// exactly once, so it must not be decided before we know where the
  /// property's records are — or a boundaryless place opens at a world view.
  bool _centreResolved = false;

  MapLibreMapController? _controller;

  /// Every located record as a GeoJSON feature — the clustering input.
  List<Map<String, dynamic>> _recordFeatures = const [];
  final Set<String> _badgeImages = {};

  /// Cluster feature id → its group, rebuilt by every paint. Taps resolve
  /// against this instead of parsing member ids out of rendered features.
  final Map<String, ClusterGroup> _clusterIndex = {};
  double? _lastPaintZoom;
  List<Map<String, dynamic>>? _lastPainted;
  bool _painting = false;
  bool _paintAgain = false;

  bool _featureLayerReady = false;
  StreamSubscription<void>? _featureSub;
  bool _photoPointLayerReady = false;
  StreamSubscription<void>? _photoPointSub;

  bool _recordLayersReady = false;
  StreamSubscription<void>? _recordSub;

  bool _framedRecords = false;
}
