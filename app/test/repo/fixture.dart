import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:field_notes/db/database.dart';

/// One place with two zones, one species and a handful of records — the
/// seed every repo test reads from. Coordinates sit in Lampasas County so
/// zone geometry and nearby-distance maths are realistic.
class RepoFixture {
  RepoFixture._(this.db);

  final FieldNotesDb db;
  late final String propertyId;
  late final String northZoneId;
  late final String creekZoneId;
  late final String burOakId;
  late final String now;

  static const lng = -98.5470;
  static const lat = 30.8830;

  static Future<RepoFixture> seed(FieldNotesDb db) async {
    final f = RepoFixture._(db);
    await f._seed();
    return f;
  }

  static String ring(double lng, double lat, double w, double h) => jsonEncode({
    'type': 'Polygon',
    'coordinates': [
      [
        [lng - w, lat - h],
        [lng + w, lat - h],
        [lng + w, lat + h],
        [lng - w, lat + h],
        [lng - w, lat - h],
      ],
    ],
  });

  Future<void> _seed() async {
    now = nowUtcIso();
    propertyId = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propertyId,
            name: 'Cedar Break Ranch',
            county: const Value('Lampasas'),
            state: const Value('TX'),
            boundaryGeojson: Value(ring(lng, lat, 0.007, 0.006)),
            centroidLat: const Value(lat),
            centroidLng: const Value(lng),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    northZoneId = await zone('North Pasture', dx: -0.0015, dy: 0.0035);
    creekZoneId = await zone('Creek Corridor', dx: 0.0005, dy: -0.0005);
    burOakId = newId();
    await db
        .into(db.taxa)
        .insert(
          TaxaCompanion.insert(
            id: burOakId,
            scientificName: 'Quercus macrocarpa',
            commonName: const Value('Bur Oak'),
            growthForm: const Value('tree'),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<String> zone(
    String name, {
    double dx = 0,
    double dy = 0,
    bool hidden = false,
  }) async {
    final id = newId();
    await db
        .into(db.zones)
        .insert(
          ZonesCompanion.insert(
            id: id,
            propertyId: propertyId,
            name: name,
            geojson: ring(lng + dx, lat + dy, 0.004, 0.002),
            hidden: Value(hidden ? 1 : 0),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  /// A record [j] degrees off the centroid. `accuracy: -1` marks "no fix".
  Future<String> record({
    String type = 'general',
    String? taxonId,
    String? zoneId,
    double j = 0,
    double? accuracy = 4.0,
    String? observedAt,
    String? notes,
    String? removalStatus,
    String? envContextId,
  }) async {
    final id = newId();
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: id,
            propertyId: propertyId,
            zoneId: Value(zoneId),
            observedAt: observedAt ?? now,
            localTz: 'CDT',
            lat: lat + j,
            lng: lng + j,
            gpsAccuracyM: Value(accuracy),
            observationType: Value(type),
            taxonId: Value(taxonId),
            taxonConfidence: Value(taxonId == null ? null : 'certain'),
            notes: Value(notes),
            removalStatus: Value(removalStatus),
            envContextId: Value(envContextId),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  /// A media row (no file on disk) linked to [entityId].
  Future<String> media({
    required String entityId,
    String mediaType = 'photo',
    int sortOrder = 0,
    String role = 'primary',
    String? localPath,
  }) async {
    final id = newId();
    await db
        .into(db.media)
        .insert(
          MediaCompanion.insert(
            id: id,
            propertyId: propertyId,
            mediaType: mediaType,
            localPath: Value(localPath ?? '/nowhere/$id.jpg'),
            thumbPath: Value(
              mediaType == 'photo' ? '/nowhere/$id.thumb.jpg' : null,
            ),
            capturedAt: Value(now),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.mediaLinks)
        .insert(
          MediaLinksCompanion.insert(
            id: newId(),
            propertyId: propertyId,
            mediaId: id,
            entityType: 'observation',
            entityId: entityId,
            role: Value(role),
            sortOrder: Value(sortOrder),
            createdAt: now,
          ),
        );
    return id;
  }
}
