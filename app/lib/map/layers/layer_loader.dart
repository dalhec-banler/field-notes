import 'package:drift/drift.dart';

import '../../db/database.dart';
import '../../geo/acres.dart';
import '../../repo/observations_repo.dart';
import '../../repo/photo_points_repo.dart';
import '../../repo/zones_repo.dart';
import '../imagery_sources.dart';
import 'map_layers.dart';

/// The one loader (D-038 item 11): builds a [MapLayerSet] for a place from
/// the repos, so the phone map, the desk map and the plate all draw from
/// the same answer to "what does this place have?".
///
/// The rules every surface used to repeat live here once:
/// - soft-deleted rows are out everywhere;
/// - hidden zones do not paint (`zonesToDraw`, D-037) — they still own
///   their records;
/// - a record saved without a fix (`gps_accuracy_m = -1`) is never drawn
///   as though it were surveyed (external audit 2026-09-04, finding 14);
/// - a record's label is its species, common name first;
/// - the ledger's filter, when a caller hands one in, narrows the records
///   the way the ledger itself is narrowed (D-024's one filter).
class MapLayerLoader {
  MapLayerLoader(
    this.db, {
    ObservationsRepo? observations,
    ZonesRepo? zones,
    PhotoPointsRepo? photoPoints,
  }) : observations = observations ?? ObservationsRepo(db),
       zones = zones ?? ZonesRepo(db),
       photoPoints = photoPoints ?? PhotoPointsRepo(db);

  final FieldNotesDb db;
  final ObservationsRepo observations;
  final ZonesRepo zones;
  final PhotoPointsRepo photoPoints;

  /// The tables a layer set is read from. A watch on these fires once and
  /// then on any change that could move a mark.
  Set<ResultSetImplementation> get tables => {
    db.properties,
    db.zones,
    db.tracks,
    db.features,
    db.featureTypes,
    db.photoPoints,
    db.protocolSites,
    db.observations,
    db.taxa,
  };

  /// Fires once on listen, then whenever any of [tables] changes.
  Stream<void> get changes => db.changes(tables);

  /// Build the layer set for [property].
  ///
  /// [filter] narrows the records (the phone passes the ledger's filter;
  /// the desk and the plate pass nothing and draw every located record).
  /// [withPhotos] also resolves each record's first photo — the removal
  /// plan prints it beside the pin; the maps never read it, so they skip
  /// the two extra queries.
  Future<MapLayerSet> load(
    Property property, {
    LedgerQuery? filter,
    bool withPhotos = false,
    LayerVisibility visibility = const LayerVisibility(),
  }) async {
    final drawnZones = await zones.toDraw(property.id);
    final tracks =
        await (db.select(db.tracks)
              ..where((t) => t.propertyId.equals(property.id))
              ..where((t) => t.deletedAt.isNull())
              ..where((t) => t.geojson.isNotNull()))
            .get();
    final types = {
      for (final t in await db.select(db.featureTypes).get()) t.id: t,
    };
    final features =
        await (db.select(db.features)
              ..where((f) => f.propertyId.equals(property.id))
              ..where((f) => f.deletedAt.isNull()))
            .get();
    final stations = await photoPoints.on(property.id);
    final sites =
        await (db.select(db.protocolSites)
              ..where((s) => s.propertyId.equals(property.id))
              ..where((s) => s.deletedAt.isNull()))
            .get();
    final pins = await observations.pins(property.id);
    final kept = filter == null ? pins : _narrow(pins, filter);
    final photoByObs = withPhotos
        ? await _firstPhotos([for (final p in kept) p.id])
        : const <String, String>{};

    return MapLayerSet.of(
      propertyName: property.name,
      visibility: visibility,
      imagery: imageryBaseOf(activeImagery),
      boundaryGeojson: property.boundaryGeojson,
      zones: [
        for (final z in drawnZones)
          ZoneShape(
            id: z.id,
            name: z.name,
            geojson: z.geojson,
            colorHex: z.colorHex,
            areaAcres: z.areaAcres ?? acresOf(z.geojson),
          ),
      ],
      tracks: [
        for (final t in tracks)
          TrackLine(id: t.id, geojson: t.geojson!, label: t.purpose),
      ],
      features: [
        for (final f in features)
          FeatureMark(
            id: f.id,
            name: f.name ?? types[f.featureTypeId]?.label ?? 'Feature',
            featureClass: types[f.featureTypeId]?.featureClass ?? 'natural',
            geojson: f.geojson,
          ),
      ],
      stations: [
        for (final p in stations)
          PhotoStation(
            id: p.id,
            name: p.name,
            lat: p.lat,
            lng: p.lng,
            bearingDeg: p.bearingDeg,
            focalLengthMm: p.focalLengthMm,
            viewExtentM: p.viewExtentM ?? 60,
            // A point with no bearing yet (never captured) is a station
            // only — it doesn't claim to look anywhere.
            hasView: !(p.bearingDeg == 0 && p.referenceMediaId == null),
          ),
      ],
      sites: [
        for (final s in sites)
          ProtocolSiteMark(
            id: s.id,
            protocolId: s.protocolId,
            name: s.name,
            lat: s.lat,
            lng: s.lng,
            geojson: s.geojson,
            retiredOn: s.retiredOn,
          ),
      ],
      records: [
        for (final r in kept)
          MapRecord(
            id: r.id,
            lat: r.lat,
            lng: r.lng,
            type: r.type,
            label: r.species,
            observedAt: r.observedAt,
            removal: r.removalStatus,
            nativity: r.nativity,
            notes: r.notes,
            photoPath: photoByObs[r.id],
            taxonId: r.taxonId,
            zoneId: r.zoneId,
            growthForm: r.growthForm,
          ),
      ],
    );
  }

  /// [load], once now and again on every change to the tables it reads.
  /// [filter] is asked each time, so a live ledger filter is honoured.
  Stream<MapLayerSet> watch(
    Property property, {
    LedgerQuery? Function()? filter,
    bool withPhotos = false,
    LayerVisibility visibility = const LayerVisibility(),
  }) => changes.asyncMap(
    (_) => load(
      property,
      filter: filter?.call(),
      withPhotos: withPhotos,
      visibility: visibility,
    ),
  );

  /// The ledger is the filter: the map draws exactly what it lists.
  static List<RecordPin> _narrow(List<RecordPin> pins, LedgerQuery q) {
    final from = q.fromUtc;
    final to = q.toUtc;
    return [
      for (final r in pins)
        if ((q.type == null || r.type == q.type) &&
            (!q.flagged || r.removalStatus == 'flagged') &&
            (q.taxonId == null || r.taxonId == q.taxonId) &&
            (q.zoneId == null || r.zoneId == q.zoneId) &&
            (from == null ||
                to == null ||
                (r.observedAt.compareTo(from) >= 0 &&
                    r.observedAt.compareTo(to) < 0)))
          r,
    ];
  }

  /// Each record's first photo (thumbnail when there is one). Media stays
  /// on this machine; only a plan the person saves carries it. Primary
  /// first; otherwise whichever link came first.
  Future<Map<String, String>> _firstPhotos(List<String> observationIds) async {
    final photoByObs = <String, String>{};
    if (observationIds.isEmpty) return photoByObs;
    final links =
        await (db.select(db.mediaLinks)
              ..where((l) => l.entityType.equals('observation'))
              ..where((l) => l.deletedAt.isNull())
              ..where((l) => l.entityId.isIn(observationIds)))
            .get();
    if (links.isEmpty) return photoByObs;
    final media = {
      for (final m
          in await (db.select(db.media)
                ..where((m) => m.id.isIn([for (final l in links) l.mediaId]))
                ..where((m) => m.mediaType.equals('photo'))
                ..where((m) => m.deletedAt.isNull()))
              .get())
        m.id: m,
    };
    for (final l in links) {
      final m = media[l.mediaId];
      final path = m?.thumbPath ?? m?.localPath;
      if (path == null) continue;
      if (l.role == 'primary' || !photoByObs.containsKey(l.entityId)) {
        photoByObs[l.entityId] = path;
      }
    }
    return photoByObs;
  }
}

/// The imagery descriptor for a source — the layer set carries this; each
/// surface builds its own tiles from it.
ImageryBase imageryBaseOf(ImagerySource s) => ImageryBase(
  sourceId: s.id,
  label: s.label,
  template: s.template,
  maxZoom: s.maxZoom,
  attribution: s.attribution,
);
