/// One layer model for every map surface (D-038 item 11).
///
/// The phone map, the desk map and the printed plate used to each decide
/// for themselves which layers a place has — records by shape and removal
/// state, clusters, the zones that paint, the boundary, photo points with
/// their view wedges, the walked tracks, the features — with their own
/// loading code and their own drawing switch. Now a layer is defined once,
/// here, as geometry plus the mark descriptors from `record_ink.dart`;
/// `layer_loader.dart` builds a [MapLayerSet] from the repos, and each
/// surface keeps only its own drawing: GeoJSON sources on the phone, a
/// Canvas on the desk, the plate's supersampled raster.
///
/// Nothing in this file knows about widgets, MapLibre or `dart:ui`. It is
/// data a test can build by hand.
library;

import 'dart:math' as math;

import '../../geo/view_wedge.dart';
import '../record_clusters.dart' show centreOf, clusterBy;
import '../record_ink.dart';

/// The layers a map can carry, in draw order: imagery underneath, then
/// the place's geometry, the stations, the records and their clusters,
/// and the person's own position on top of everything.
enum MapLayerKind {
  imagery,
  zones,
  boundary,
  tracks,
  features,
  photoPoints,
  protocolSites,
  records,
  clusters,
  position,
}

/// One drawable layer. Each subtype carries a typed payload — geometry and
/// mark descriptors only — so a renderer's switch is exhaustive and a
/// surface that does not draw a layer says so with an empty case.
sealed class MapLayer {
  const MapLayer();
  MapLayerKind get kind;
  bool get isEmpty;
}

// ── imagery ──────────────────────────────────────────────────────────

/// Where the imagery under everything comes from. A descriptor, not a
/// tile fetcher: the phone's style, the desk's fetcher and the plate's
/// fetcher are each built from it on their own side.
class ImageryBase extends MapLayer {
  const ImageryBase({
    required this.sourceId,
    required this.label,
    required this.template,
    required this.maxZoom,
    required this.attribution,
  });

  final String sourceId;
  final String label;

  /// XYZ template with {z}/{x}/{y} placeholders.
  final String template;
  final int maxZoom;
  final String attribution;

  @override
  MapLayerKind get kind => MapLayerKind.imagery;
  @override
  bool get isEmpty => false;
}

// ── zones ────────────────────────────────────────────────────────────

/// The palette a zone without a stored colour falls back to, by its
/// position among the zones that draw. The desk and the plate have always
/// resolved zone ink this way; the phone draws every zone in one green.
const zoneFillPalette = [
  0xFF4E6B4A,
  0xFF7A8C3B,
  0xFFA8791F,
  0xFF2F5D8A,
  0xFF8B2E22,
  0xFF5D5A8A,
  0xFF3F7A73,
  0xFFB5652B,
  0xFF6B7F2E,
  0xFF7E4E7A,
];

/// ARGB for `#RRGGBB` / `#AARRGGBB`, or null when it isn't one.
int? parseHexArgb(String? hex) {
  if (hex == null) return null;
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  return int.tryParse(h, radix: 16);
}

/// The colour a zone draws in: its own, else the palette slot for its
/// position in the drawn list.
int zoneInkFor(String? colorHex, int index) =>
    parseHexArgb(colorHex) ?? zoneFillPalette[index % zoneFillPalette.length];

class ZoneShape {
  const ZoneShape({
    required this.name,
    required this.geojson,
    this.colorHex,
    this.areaAcres,
    this.id,
  });

  final String? id;
  final String name;
  final String geojson; // Polygon / MultiPolygon
  final String? colorHex;
  final double? areaAcres;
}

/// The zones that paint — hidden zones never reach this list (D-037).
class ZoneFills extends MapLayer {
  const ZoneFills(this.zones);
  final List<ZoneShape> zones;

  /// The ink of the zone at [index], resolved as every surface resolves it.
  int inkAt(int index) => zoneInkFor(zones[index].colorHex, index);

  @override
  MapLayerKind get kind => MapLayerKind.zones;
  @override
  bool get isEmpty => zones.isEmpty;
}

// ── boundary ─────────────────────────────────────────────────────────

class BoundaryLine extends MapLayer {
  const BoundaryLine(this.geojson);
  final String geojson; // Polygon / MultiPolygon

  @override
  MapLayerKind get kind => MapLayerKind.boundary;
  @override
  bool get isEmpty => geojson.isEmpty;
}

// ── tracks ───────────────────────────────────────────────────────────

class TrackLine {
  const TrackLine({required this.geojson, this.label, this.id});
  final String? id;
  final String geojson; // LineString
  final String? label;
}

class TrackLines extends MapLayer {
  const TrackLines(this.tracks);
  final List<TrackLine> tracks;

  @override
  MapLayerKind get kind => MapLayerKind.tracks;
  @override
  bool get isEmpty => tracks.isEmpty;
}

// ── features ─────────────────────────────────────────────────────────

/// The ink of a feature class — springs and seeps in river, the built in
/// ink, trouble in oxblood — the same on every surface.
int featureClassInk(String featureClass) => switch (featureClass) {
  'problem' => 0xFF8B2E22,
  'infrastructure' => 0xFF1B1813,
  _ => 0xFF2F5D8A,
};

class FeatureMark {
  const FeatureMark({
    required this.name,
    required this.featureClass, // natural | infrastructure | problem
    required this.geojson,
    this.id,
  });

  final String? id;
  final String name;
  final String featureClass;
  final String geojson; // Point / LineString / Polygon

  int get ink => featureClassInk(featureClass);
}

class FeatureMarks extends MapLayer {
  const FeatureMarks(this.features);
  final List<FeatureMark> features;

  @override
  MapLayerKind get kind => MapLayerKind.features;
  @override
  bool get isEmpty => features.isEmpty;
}

// ── photo points ─────────────────────────────────────────────────────

/// A monitoring station: a spot AND a direction AND a field of view. One
/// that has never been shot ([hasView] false) is a bug alone — it does not
/// yet claim to look anywhere.
class PhotoStation {
  const PhotoStation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.bearingDeg,
    required this.hasView,
    this.focalLengthMm,
    this.viewExtentM = 60,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final double bearingDeg;
  final double? focalLengthMm;
  final double viewExtentM;
  final bool hasView;

  /// GeoJSON Polygon ring of the ground this station frames.
  List<List<double>> get wedge => viewWedge(
    lat: lat,
    lng: lng,
    bearingDeg: bearingDeg,
    focalLengthMm: focalLengthMm,
    extentM: viewExtentM,
  );

  /// The centre line of the view, as a GeoJSON LineString's coordinates.
  List<List<double>> get axis =>
      viewAxis(lat: lat, lng: lng, bearingDeg: bearingDeg, extentM: viewExtentM);
}

class PhotoPointStations extends MapLayer {
  const PhotoPointStations(this.stations);
  final List<PhotoStation> stations;

  @override
  MapLayerKind get kind => MapLayerKind.photoPoints;
  @override
  bool get isEmpty => stations.isEmpty;
}

// ── protocol sites ───────────────────────────────────────────────────

/// A monitoring protocol's site (D-033): the origin of a line, the centre
/// of a plot, or a point. Defined here so the layer exists once; no
/// surface draws it yet.
class ProtocolSiteMark {
  const ProtocolSiteMark({
    required this.id,
    required this.protocolId,
    required this.name,
    required this.lat,
    required this.lng,
    this.geojson,
    this.retiredOn,
  });

  final String id;
  final String protocolId;
  final String name;
  final double lat;
  final double lng;
  final String? geojson; // Point | LineString | Polygon, derived on save
  final String? retiredOn;
}

class ProtocolSiteMarks extends MapLayer {
  const ProtocolSiteMarks(this.sites);
  final List<ProtocolSiteMark> sites;

  @override
  MapLayerKind get kind => MapLayerKind.protocolSites;
  @override
  bool get isEmpty => sites.isEmpty;
}

// ── records ──────────────────────────────────────────────────────────

/// One located record as every map draws it: where it is, what kind of
/// thing it is ([mark] from the one mark table), what colours a named
/// plant ([growthForm]), whether it is coming out ([removal], D-027), and
/// the columns the ledger's filter reads. [nativity], [notes] and
/// [photoPath] ride along for the removal plan's list; no renderer reads
/// them.
class MapRecord {
  const MapRecord({
    required this.lat,
    required this.lng,
    required this.type,
    this.label,
    this.id,
    this.observedAt,
    this.removal,
    this.nativity,
    this.notes,
    this.photoPath,
    this.taxonId,
    this.zoneId,
    this.growthForm,
  });

  final double lat, lng;
  final String type; // observation_type

  /// Species, when identified: common name first, else scientific.
  final String? label;

  /// Observation id — a hand-built subject may leave it out; the loader
  /// always sets it.
  final String? id;
  final String? observedAt;

  /// D-027: 'flagged' or 'removed', when this record is removal work.
  final String? removal;

  final String? nativity;
  final String? notes;
  final String? photoPath;

  final String? taxonId;
  final String? zoneId;

  /// The species' growth form, when the record names a plant.
  final String? growthForm;

  /// Shape and domain colour from the one mark table.
  RecordMark get mark => markFor(type);

  /// What the phone keys colour and dot size on: growth form when the
  /// record names a plant, otherwise the record type.
  String get kind => growthForm ?? type;

  /// Which section this record lists under.
  RecordRealm get realm =>
      label != null ? RecordRealm.species : realmOfType(type);
}

(double lat, double lng) recordCoords(MapRecord r) => (r.lat, r.lng);

class RecordMarks extends MapLayer {
  const RecordMarks(this.records);
  final List<MapRecord> records;

  @override
  MapLayerKind get kind => MapLayerKind.records;
  @override
  bool get isEmpty => records.isEmpty;
}

// ── clusters ─────────────────────────────────────────────────────────

/// One screen cell's worth of records at a zoom: a single mark, or a
/// badge with a count.
class RecordCell {
  const RecordCell(this.members);
  final List<MapRecord> members;

  bool get isCluster => members.length > 1;

  /// Mean position of the members.
  (double lat, double lng) get centre => centreOf(members, recordCoords);

  List<String> get ids => [
    for (final m in members)
      if (m.id != null) m.id!,
  ];
}

/// Records grouped into screen cells at one zoom, the way `record_clusters`
/// groups them — the phone and the desk badge the same clusters because
/// both ask this.
class RecordClusters extends MapLayer {
  const RecordClusters(this.cells, {required this.zoom});

  factory RecordClusters.at(
    List<MapRecord> records,
    double zoom, {
    double cellPx = 26,
  }) => RecordClusters([
    for (final cell in clusterBy(records, recordCoords, zoom, cellPx: cellPx))
      RecordCell(cell),
  ], zoom: zoom);

  final List<RecordCell> cells;
  final double zoom;

  Iterable<RecordCell> get clusters => cells.where((c) => c.isCluster);
  Iterable<MapRecord> get singles => [
    for (final c in cells)
      if (!c.isCluster) c.members.single,
  ];

  @override
  MapLayerKind get kind => MapLayerKind.clusters;
  @override
  bool get isEmpty => cells.isEmpty;
}

// ── position ─────────────────────────────────────────────────────────

/// Your own position: the fix and how well the phone knows it. The ring is
/// ground coordinates, so it scales with the map instead of pretending to
/// be a fixed number of pixels.
class PositionMark extends MapLayer {
  const PositionMark({
    required this.lat,
    required this.lng,
    required this.accuracyM,
  });

  final double lat;
  final double lng;
  final double accuracyM;

  /// A ring is worth drawing when the fix has a finite, non-trivial error.
  bool get hasRing => accuracyM.isFinite && accuracyM > 1;

  /// The accuracy circle as a closed GeoJSON ring of `[lng, lat]`.
  List<List<double>> ring({int steps = 36}) {
    final dLat = accuracyM / 111320.0;
    final dLng = accuracyM / (111320.0 * math.cos(lat * math.pi / 180).abs());
    return [
      for (var i = 0; i <= steps; i++)
        [
          lng + dLng * math.sin(2 * math.pi * i / steps),
          lat + dLat * math.cos(2 * math.pi * i / steps),
        ],
    ];
  }

  @override
  MapLayerKind get kind => MapLayerKind.position;
  @override
  bool get isEmpty => false;
}

// ── visibility ───────────────────────────────────────────────────────

/// Which layers draw. Mirrors the phone's layers sheet (zones, tracks,
/// features, photo points, satellite) and the plate's `PlateLayers`
/// (boundary, zones, zone labels, features, records, tracks). Records on a
/// plate default off because they carry the coordinates of private land
/// (hard rule 3); that default is the plate's to set, not this class's.
class LayerVisibility {
  const LayerVisibility({
    this.imagery = true,
    this.zones = true,
    this.zoneLabels = true,
    this.boundary = true,
    this.tracks = true,
    this.features = true,
    this.photoPoints = true,
    this.protocolSites = true,
    this.records = true,
    this.position = true,
  });

  final bool imagery;
  final bool zones;

  /// Zone names drawn at the centroid — a plate thing; the phone and the
  /// desk never label zones on the map itself.
  final bool zoneLabels;
  final bool boundary;
  final bool tracks;
  final bool features;
  final bool photoPoints;
  final bool protocolSites;
  final bool records;
  final bool position;

  bool isOn(MapLayerKind kind) => switch (kind) {
    MapLayerKind.imagery => imagery,
    MapLayerKind.zones => zones,
    MapLayerKind.boundary => boundary,
    MapLayerKind.tracks => tracks,
    MapLayerKind.features => features,
    MapLayerKind.photoPoints => photoPoints,
    MapLayerKind.protocolSites => protocolSites,
    MapLayerKind.records || MapLayerKind.clusters => records,
    MapLayerKind.position => position,
  };

  LayerVisibility copyWith({
    bool? imagery,
    bool? zones,
    bool? zoneLabels,
    bool? boundary,
    bool? tracks,
    bool? features,
    bool? photoPoints,
    bool? protocolSites,
    bool? records,
    bool? position,
  }) => LayerVisibility(
    imagery: imagery ?? this.imagery,
    zones: zones ?? this.zones,
    zoneLabels: zoneLabels ?? this.zoneLabels,
    boundary: boundary ?? this.boundary,
    tracks: tracks ?? this.tracks,
    features: features ?? this.features,
    photoPoints: photoPoints ?? this.photoPoints,
    protocolSites: protocolSites ?? this.protocolSites,
    records: records ?? this.records,
    position: position ?? this.position,
  );
}

// ── the set ──────────────────────────────────────────────────────────

/// Every layer a place has, in draw order, with what is switched on. One
/// of these is what a surface renders; the loader builds it from the
/// database and `PlateSubject` is a view over it.
class MapLayerSet {
  const MapLayerSet({
    required this.propertyName,
    required this.layers,
    this.visibility = const LayerVisibility(),
  });

  /// Lay the layers out in [MapLayerKind] order. Absent payloads are
  /// carried as empty layers so a renderer's loop is the same shape for
  /// every place; the boundary and the position are present only when
  /// there is one.
  factory MapLayerSet.of({
    required String propertyName,
    ImageryBase? imagery,
    List<ZoneShape> zones = const [],
    String? boundaryGeojson,
    List<TrackLine> tracks = const [],
    List<FeatureMark> features = const [],
    List<PhotoStation> stations = const [],
    List<ProtocolSiteMark> sites = const [],
    List<MapRecord> records = const [],
    PositionMark? position,
    LayerVisibility visibility = const LayerVisibility(),
  }) => MapLayerSet(
    propertyName: propertyName,
    visibility: visibility,
    layers: [
      ?imagery,
      ZoneFills(zones),
      if (boundaryGeojson != null) BoundaryLine(boundaryGeojson),
      TrackLines(tracks),
      FeatureMarks(features),
      PhotoPointStations(stations),
      ProtocolSiteMarks(sites),
      RecordMarks(records),
    ],
  );

  final String propertyName;
  final List<MapLayer> layers;
  final LayerVisibility visibility;

  /// The first layer of type [T], if the set carries one.
  T? layer<T extends MapLayer>() => layers.whereType<T>().firstOrNull;

  /// The layers that are switched on, in draw order.
  Iterable<MapLayer> get visible =>
      layers.where((l) => visibility.isOn(l.kind));

  ImageryBase? get imagery => layer<ImageryBase>();
  List<ZoneShape> get zones => layer<ZoneFills>()?.zones ?? const [];
  String? get boundaryGeojson => layer<BoundaryLine>()?.geojson;
  List<TrackLine> get tracks => layer<TrackLines>()?.tracks ?? const [];
  List<FeatureMark> get features =>
      layer<FeatureMarks>()?.features ?? const [];
  List<PhotoStation> get stations =>
      layer<PhotoPointStations>()?.stations ?? const [];
  List<ProtocolSiteMark> get sites =>
      layer<ProtocolSiteMarks>()?.sites ?? const [];
  List<MapRecord> get records => layer<RecordMarks>()?.records ?? const [];
  PositionMark? get position => layer<PositionMark>();

  /// The records grouped into screen cells at [zoom] — the clusters layer,
  /// derived on demand because it depends on the camera.
  RecordClusters clustersAt(double zoom, {double cellPx = 26}) =>
      RecordClusters.at(records, zoom, cellPx: cellPx);

  MapLayerSet withVisibility(LayerVisibility v) =>
      MapLayerSet(propertyName: propertyName, layers: layers, visibility: v);
}
