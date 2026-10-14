import 'package:drift/drift.dart';

import '../db/database.dart';
import '../geo/acres.dart';
import 'map_plate.dart';

// Acreage used to live here; it is geometry, not export, and the polygon
// editor reads it too. Kept reachable from the old address.
export '../geo/acres.dart' show acresOf, acresOfRing;

/// Assemble the plate's subject from the property's live rows. Soft-deleted
/// rows are excluded everywhere; a record's label is the species when it
/// has one (common name first), else nothing.
Future<PlateSubject> loadPlateSubject(
  FieldNotesDb db,
  Property property,
) async {
  // Hidden zones don't paint — not on the desk map, not on a plate, not in
  // an export. They still exist and still own their records.
  final zones = await db.zonesToDraw(property.id);
  final types = {
    for (final t in await db.select(db.featureTypes).get()) t.id: t,
  };
  final features =
      await (db.select(db.features)
            ..where((f) => f.propertyId.equals(property.id))
            ..where((f) => f.deletedAt.isNull()))
          .get();
  final taxa = {for (final t in await db.select(db.taxa).get()) t.id: t};
  final observations =
      await (db.select(db.observations)
            ..where((o) => o.propertyId.equals(property.id))
            ..where((o) => o.deletedAt.isNull())
            // A record saved without a fix carries gps_accuracy_m = -1 and
            // placeholder coordinates. It must not be drawn as though it
            // were surveyed — it used to land at (0, 0) or at a fabricated
            // centroid, and it stretched the desk map's framing across the
            // ocean (external audit 2026-09-04, finding 14). The full
            // GeoJSON export always honoured the flag; now the plate,
            // the desk map and the HTML agree with it.
            ..where(
              (o) => o.gpsAccuracyM.equals(-1).not() | o.gpsAccuracyM.isNull(),
            ))
          .get();
  // Each record's first photo (thumbnail when there is one) — the removal
  // plan prints it beside the pin. Media stays on this machine; only the
  // plan the person saves carries it.
  final photoByObs = <String, String>{};
  if (observations.isNotEmpty) {
    final links =
        await (db.select(db.mediaLinks)
              ..where((l) => l.entityType.equals('observation'))
              ..where((l) => l.deletedAt.isNull())
              ..where(
                (l) => l.entityId.isIn([for (final o in observations) o.id]),
              ))
            .get();
    if (links.isNotEmpty) {
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
        // Primary first; otherwise whichever link came first.
        if (l.role == 'primary' || !photoByObs.containsKey(l.entityId)) {
          photoByObs[l.entityId] = path;
        }
      }
    }
  }
  final tracks =
      await (db.select(db.tracks)
            ..where((t) => t.propertyId.equals(property.id))
            ..where((t) => t.deletedAt.isNull())
            ..where((t) => t.geojson.isNotNull()))
          .get();

  return PlateSubject(
    propertyName: property.name,
    boundaryGeojson: property.boundaryGeojson,
    zones: [
      for (final z in zones)
        PlateZone(
          name: z.name,
          geojson: z.geojson,
          colorHex: z.colorHex,
          areaAcres: z.areaAcres ?? acresOf(z.geojson),
        ),
    ],
    features: [
      for (final f in features)
        PlateFeature(
          id: f.id,
          name: f.name ?? types[f.featureTypeId]?.label ?? 'Feature',
          featureClass: types[f.featureTypeId]?.featureClass ?? 'natural',
          geojson: f.geojson,
        ),
    ],
    records: [
      for (final o in observations)
        PlateRecord(
          id: o.id,
          lat: o.lat,
          lng: o.lng,
          type: o.observationType,
          label: o.taxonId == null
              ? null
              : taxa[o.taxonId]?.commonName ?? taxa[o.taxonId]?.scientificName,
          observedAt: o.observedAt,
          removal: o.removalStatus,
          nativity: o.taxonId == null ? null : taxa[o.taxonId]?.nativity,
          notes: o.notes,
          photoPath: photoByObs[o.id],
        ),
    ],
    tracks: [
      for (final t in tracks) PlateTrack(geojson: t.geojson!, label: t.purpose),
    ],
  );
}
