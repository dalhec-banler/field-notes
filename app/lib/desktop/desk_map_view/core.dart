part of '../desk_map_view.dart';

const _retryAfter = Duration(seconds: 15);

/// The desk map's state: the layer set and selection, camera, tile cache
/// and images, layout, cluster cache, and the feature-panel load.
mixin _DeskMapCore on State<DeskMapWorkspace> {
  // Defined in later parts of the chain; declared here so the fields
  // above and the marks can reach them.
  TileFetcher _buildFetcher();
  void _closeFeature();

  /// The one answer to what this place draws (D-038 item 11).
  late final MapLayerLoader _loader = MapLayerLoader(widget.db);

  MapLayerSet? _layers;
  String? _selectedId;
  String? _selectedFeatureId;

  /// The species group lit on the map and opened in the panel.
  String? _highlightKey;
  StreamSubscription<void>? _watch;

  // Camera.
  double? _lat, _lng;
  double _zoom = 15;

  // Tiles: bytes are LRU-cached across the session; decoded images live
  // for this view. A fetch in flight is never issued twice.
  final _tiles = TileCache();
  late TileFetcher _fetch = _buildFetcher();
  final _images = <String, ui.Image>{};
  final _inflight = <String>{};
  // A failed tile is retried after a beat — one bad request must
  // not blank that tile for the whole session (audit 2026-09-04).
  final _retryAt = <String, DateTime>{};

  String _fetchSourceId = activeImagery.id;
  int _tileEpoch = 0;

  Size _lastLayoutSize = const Size(900, 700);
  double _panZoomScale = 1.0;
  bool _sizedFrame = false;
  bool _userMoved = false;

  // ── camera math ──────────────────────────────────────────────────

  /// On a retina display, drawing one tile pixel per LOGICAL pixel doubles
  /// everything and the imagery reads soft — "still isn't Esri" (Austin,
  /// 2026-09-03). Fetch one zoom deeper and draw at half size instead, so
  /// tile pixels land on device pixels.
  int _dprBoost = 0;

  int get _zInt => (_zoom.floor() + _dprBoost).clamp(3, activeImagery.maxZoom);
  double get _tileScale => math.pow(2.0, _zoom - _zInt).toDouble();

  // ── clusters ─────────────────────────────────────────────────────

  /// Records grouped for the current zoom exactly as the phone groups
  /// them (record_clusters.dart): one screen cell, one badge with a count
  /// (Austin, 2026-09-06: "the dots don't combine into 1 with a number").
  /// Lit and dimmed sets group separately, so a highlighted species'
  /// badge counts only that species; the selected record always stands
  /// alone so its halo shows. Regrouped when zoom, subject, highlight or
  /// selection change — a pan reuses the last grouping.
  (List<List<MapRecord>>, List<List<MapRecord>>) _clusters = (
    const [],
    const [],
  );
  (double, MapLayerSet, String?, String?)? _clusterKey;

  /// A clicked feature: what it is, its condition history, and the
  /// controls the phone has — log lives there; DELETE lives here too.
  Future<List<Object?>>? _featureLoad;
  (String, MapLayerSet?)? _featureLoadKey;
}
