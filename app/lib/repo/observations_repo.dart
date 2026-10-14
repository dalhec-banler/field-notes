import 'dart:io';

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../geo/simplify.dart' show distanceM;
import '../geo/zone_assignment.dart';
import '../services/observation_ops.dart' as ops;
import '../sync/oplog.dart';

/// What the ledger has been narrowed to (D-038 item 5). Plain data: the
/// ledger's chips write a [RecordFilter], the filter renders one of these,
/// and the repo turns it into SQL. Dates arrive already converted to UTC
/// ISO bounds — the local-midnight arithmetic lives with the filter.
class LedgerQuery {
  const LedgerQuery({
    this.zoneId,
    this.type,
    this.taxonId,
    this.flagged = false,
    this.fromUtc,
    this.toUtc,
  });

  final String? zoneId;
  final String? type;
  final String? taxonId;

  /// Only records flagged for removal (D-027).
  final bool flagged;

  /// Half-open `[fromUtc, toUtc)` on `observed_at`; both or neither.
  final String? fromUtc;
  final String? toUtc;
}

/// One record as the map draws it: the pin's position, what colours it,
/// and the columns the filter reads. The species name is already resolved.
class RecordPin {
  const RecordPin({
    required this.id,
    required this.lat,
    required this.lng,
    required this.type,
    required this.observedAt,
    this.taxonId,
    this.zoneId,
    this.removalStatus,
    this.growthForm,
    this.species,
    this.nativity,
    this.notes,
  });

  final String id;
  final double lat;
  final double lng;
  final String type;
  final String observedAt;
  final String? taxonId;
  final String? zoneId;
  final String? removalStatus;
  final String? growthForm;

  /// Common name, else scientific; null when the record names no taxon.
  final String? species;

  /// The species' nativity and the record's notes — what the removal
  /// plan prints beside a numbered pin. No map draws them.
  final String? nativity;
  final String? notes;
}

/// The spread of a place's located records: mean, count and bounding box.
class LocatedExtent {
  const LocatedExtent({
    required this.count,
    this.meanLat,
    this.meanLng,
    this.minLat,
    this.maxLat,
    this.minLng,
    this.maxLng,
  });

  final int count;
  final double? meanLat;
  final double? meanLng;
  final double? minLat;
  final double? maxLat;
  final double? minLng;
  final double? maxLng;
}

/// Reads and writes on `observations` and the rows that hang off one
/// record (its env context, its condition log). Screens call this; the
/// drift queries live here.
class ObservationsRepo {
  ObservationsRepo(this.db);

  final FieldNotesDb db;

  Future<Observation?> byId(String id) =>
      (db.select(db.observations)..where((o) => o.id.equals(id)))
          .getSingleOrNull();

  /// The row, or a throw: for the moment after a write when it must exist.
  Future<Observation> single(String id) =>
      (db.select(db.observations)..where((o) => o.id.equals(id))).getSingle();

  Future<void> insert(ObservationsCompanion row) =>
      db.into(db.observations).insert(row);

  /// The ledger: live records on one place, newest first, narrowed by [q].
  Stream<List<Observation>> watchLedger(String propertyId, LedgerQuery q) {
    final query = (db.select(db.observations)
      ..where((o) => o.propertyId.equals(propertyId))
      ..where((o) => o.deletedAt.isNull())
      ..orderBy([(o) => OrderingTerm.desc(o.observedAt)]));
    if (q.zoneId != null) query.where((o) => o.zoneId.equals(q.zoneId!));
    if (q.flagged) query.where((o) => o.removalStatus.equals('flagged'));
    if (q.type != null) {
      query.where((o) => o.observationType.equals(q.type!));
    }
    if (q.taxonId != null) query.where((o) => o.taxonId.equals(q.taxonId!));
    final from = q.fromUtc;
    final to = q.toUtc;
    if (from != null && to != null) {
      query.where(
        (o) =>
            o.observedAt.isBiggerOrEqual(Constant(from)) &
            o.observedAt.isSmallerThan(Constant(to)),
      );
    }
    return query.watch();
  }

  /// Live records on a place that have a location (not the -1 "no fix").
  Future<List<Observation>> located(String propertyId) =>
      (db.select(db.observations)
            ..where((o) => o.propertyId.equals(propertyId))
            ..where((o) => o.deletedAt.isNull())
            ..where(
              (o) => o.gpsAccuracyM.equals(-1).not() | o.gpsAccuracyM.isNull(),
            ))
          .get();

  /// Mean (lat, lng) of every live record on a place — located or not —
  /// as a stand-in centre when the property has no boundary yet.
  Future<(double, double)?> meanPosition(String propertyId) async {
    final row =
        await (db.selectOnly(db.observations)
              ..addColumns([db.observations.lat.avg(), db.observations.lng.avg()])
              ..where(
                db.observations.propertyId.equals(propertyId) &
                    db.observations.deletedAt.isNull(),
              ))
            .getSingleOrNull();
    final lat = row?.read(db.observations.lat.avg());
    final lng = row?.read(db.observations.lng.avg());
    if (lat == null || lng == null) return null;
    return (lat, lng);
  }

  /// Mean and bounding box of the LOCATED live records on a place.
  Future<LocatedExtent> locatedExtent(String propertyId) async {
    final row = await db
        .customSelect(
          'SELECT AVG(lat) AS lat, AVG(lng) AS lng, COUNT(*) AS n, '
          'MIN(lat) AS min_lat, MAX(lat) AS max_lat, '
          'MIN(lng) AS min_lng, MAX(lng) AS max_lng '
          'FROM observations WHERE property_id = ? AND deleted_at IS NULL '
          'AND (gps_accuracy_m IS NULL OR gps_accuracy_m != -1)',
          variables: [Variable.withString(propertyId)],
          readsFrom: {db.observations},
        )
        .getSingleOrNull();
    return LocatedExtent(
      count: (row?.data['n'] as int?) ?? 0,
      meanLat: row?.data['lat'] as double?,
      meanLng: row?.data['lng'] as double?,
      minLat: row?.data['min_lat'] as double?,
      maxLat: row?.data['max_lat'] as double?,
      minLng: row?.data['min_lng'] as double?,
      maxLng: row?.data['max_lng'] as double?,
    );
  }

  /// Every located live record on a place, joined to its species, for the
  /// map's pin layer.
  Future<List<RecordPin>> pins(String propertyId) async {
    final rows = await db
        .customSelect(
          'SELECT o.id AS id, o.lat AS lat, o.lng AS lng, '
          'o.observation_type AS type, o.gps_accuracy_m AS acc, '
          'o.taxon_id AS taxon, o.zone_id AS zone, '
          'o.observed_at AS at, '
          'o.removal_status AS removal, o.notes AS notes, '
          't.growth_form AS growth, t.nativity AS nativity, '
          'COALESCE(t.common_name, t.scientific_name) AS species '
          'FROM observations o LEFT JOIN taxa t ON t.id = o.taxon_id '
          'WHERE o.property_id = ? AND o.deleted_at IS NULL '
          'AND (o.gps_accuracy_m IS NULL OR o.gps_accuracy_m != -1)',
          variables: [Variable.withString(propertyId)],
          readsFrom: {db.observations, db.taxa},
        )
        .get();
    return [
      for (final r in rows)
        RecordPin(
          id: r.data['id'] as String,
          lat: r.data['lat'] as double,
          lng: r.data['lng'] as double,
          type: r.data['type'] as String? ?? 'general',
          observedAt: r.data['at'] as String? ?? '',
          taxonId: r.data['taxon'] as String?,
          zoneId: r.data['zone'] as String?,
          removalStatus: r.data['removal'] as String?,
          growthForm: r.data['growth'] as String?,
          species: r.data['species'] as String?,
          nativity: r.data['nativity'] as String?,
          notes: r.data['notes'] as String?,
        ),
    ];
  }

  /// Fires once, then on any change to records or the species behind them
  /// — what the map's pins follow.
  Stream<void> get pinChanges => db.changes({db.observations, db.taxa});

  /// Other located live records on the same place within [withinM] of
  /// [obs], nearest first (spec §7.4). Empty for an unlocated record.
  Future<List<(Observation, double)>> nearby(
    Observation obs, {
    double withinM = 50,
  }) async {
    if (obs.gpsAccuracyM == -1) return const [];
    final candidates =
        await (db.select(db.observations)
              ..where((o) => o.propertyId.equals(obs.propertyId))
              ..where((o) => o.deletedAt.isNull())
              ..where((o) => o.id.equals(obs.id).not())
              ..where(
                (o) =>
                    o.gpsAccuracyM.equals(-1).not() | o.gpsAccuracyM.isNull(),
              )
              ..where(
                (o) => o.lat.isBetweenValues(obs.lat - 0.001, obs.lat + 0.001),
              )
              ..where(
                (o) => o.lng.isBetweenValues(obs.lng - 0.001, obs.lng + 0.001),
              ))
            .get();
    final out = <(Observation, double)>[];
    for (final c in candidates) {
      final d = distanceM([obs.lng, obs.lat], [c.lng, c.lat]);
      if (d <= withinM) out.add((c, d));
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out;
  }

  Future<EnvContext?> envContext(String envContextId) =>
      (db.select(db.envContexts)..where((e) => e.id.equals(envContextId)))
          .getSingleOrNull();

  /// The record's condition timeline, newest first, live.
  Stream<List<ConditionLog>> watchConditionLogs(String observationId) =>
      (db.select(db.conditionLogs)
            ..where((l) => l.observationId.equals(observationId))
            ..where((l) => l.deletedAt.isNull())
            ..orderBy([(l) => OrderingTerm.desc(l.observedAt)]))
          .watch();

  Future<void> updateConditionLog(
    String id, {
    required String observedAt,
    required String condition,
    required String? actionTaken,
    required String? notes,
  }) {
    final now = nowUtcIso();
    return (db.update(db.conditionLogs)..where((x) => x.id.equals(id))).write(
      ConditionLogsCompanion(
        observedAt: Value(observedAt),
        condition: Value(condition),
        actionTaken: Value(actionTaken),
        notes: Value(notes),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> softDeleteConditionLog(String id) {
    final now = nowUtcIso();
    return (db.update(db.conditionLogs)..where((x) => x.id.equals(id))).write(
      ConditionLogsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// Removal (D-027): null clears the flag, 'flagged' raises it, 'removed'
  /// stamps today as the day it came out.
  Future<void> setRemoval(String observationId, String? status) {
    final now = nowUtcIso();
    return (db.update(db.observations)
          ..where((o) => o.id.equals(observationId)))
        .write(
          ObservationsCompanion(
            removalStatus: Value(status),
            removedOn: Value(status == 'removed' ? now.substring(0, 10) : null),
            updatedAt: Value(now),
          ),
        );
  }

  /// Hand-move the pin: accuracy becomes "placed by hand" (null, the same
  /// meaning a map-drop has) and the zone is re-derived from the new point.
  Future<void> moveTo(
    Observation obs, {
    required double lat,
    required double lng,
  }) async {
    await (db.update(db.observations)..where((o) => o.id.equals(obs.id))).write(
      ObservationsCompanion(
        lat: Value(lat),
        lng: Value(lng),
        gpsAccuracyM: const Value(null),
        zoneId: const Value(null),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    await assignZone(
      db,
      observationId: obs.id,
      propertyId: obs.propertyId,
      lat: lat,
      lng: lng,
    );
  }

  // The write paths below are the long-standing functions in
  // services/observation_ops.dart, reached through the repo so a screen
  // has one door. Their tests stay where they are.

  Future<void> softDelete(String observationId) =>
      ops.softDeleteObservation(db, observationId);

  Future<void> applyEdit(
    String observationId, {
    required String? taxonId,
    required String? taxonConfidence,
    required String observationType,
    required String observedAt,
    required String? notes,
  }) => ops.applyRecordEdit(
    db,
    observationId,
    taxonId: taxonId,
    taxonConfidence: taxonConfidence,
    observationType: observationType,
    observedAt: observedAt,
    notes: notes,
  );

  Future<ops.UndoOutcome> undo(String observationId, {OpLog? log}) =>
      ops.undoObservation(db, observationId, log: log);

  Future<void> erase(String observationId, {OpLog? log}) =>
      ops.eraseObservation(db, observationId, log: log);

  Future<List<File>> photoFiles(String observationId) =>
      ops.observationPhotoFiles(db, observationId);
}
