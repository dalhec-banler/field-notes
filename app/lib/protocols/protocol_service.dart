import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../geo/zone_assignment.dart';
import 'field_defs.dart';
import 'indicators.dart';
import 'templates.dart';

/// Monitoring: a saved spot and the same questions (D-033).
///
/// Templates are copied into a property the first time Monitoring opens
/// there, so a user's edits to a method are their own. A site is placed
/// once; a run is one visit, and every run is also an observation — the
/// record it was made as — so the ledger, map, export, review and sync
/// carry it with no new plumbing.
class ProtocolService {
  ProtocolService(this.db);

  final FieldNotesDb db;

  /// Copies the shipped templates into a property once. Idempotent by
  /// method key; a later app version with a new template adds only that.
  Future<int> ensureTemplates(String propertyId) async {
    final have =
        await (db.select(db.protocols)
              ..where((p) => p.propertyId.equals(propertyId))
              ..where((p) => p.isTemplate.equals(1)))
            .get();
    final keys = {for (final p in have) p.methodKey};
    final now = nowUtcIso();
    var added = 0;
    await db.batch((b) {
      for (final t in templates) {
        if (keys.contains(t.methodKey)) continue;
        b.insert(
          db.protocols,
          ProtocolsCompanion.insert(
            id: newId(),
            propertyId: propertyId,
            methodKey: t.methodKey,
            name: t.name,
            methodName: Value(t.methodName),
            reference: Value(t.reference),
            siteKind: t.siteKind,
            cadenceDays: Value(t.cadenceDays),
            seasonHint: Value(t.seasonHint),
            fieldsJson: t.fieldsJson,
            computesJson: Value(jsonEncode(t.computes)),
            isTemplate: const Value(1),
            isStarter: Value(t.isStarter ? 1 : 0),
            createdBy: 'template',
            createdAt: now,
            updatedAt: now,
          ),
        );
        added++;
      }
    });
    return added;
  }

  Future<List<Protocol>> protocolsFor(String propertyId) =>
      (db.select(db.protocols)
            ..where((p) => p.propertyId.equals(propertyId))
            ..where((p) => p.deletedAt.isNull())
            ..orderBy([
              (p) => OrderingTerm.desc(p.isStarter),
              (p) => OrderingTerm.asc(p.name),
            ]))
          .get();

  /// A custom protocol: the user's own questions from the same closed
  /// field-type list.
  Future<Protocol> createCustom({
    required String propertyId,
    required String name,
    required String siteKind,
    required List<FieldDef> fields,
    int? cadenceDays,
    String? methodName,
    String createdBy = 'local',
  }) async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.protocols)
        .insert(
          ProtocolsCompanion.insert(
            id: id,
            propertyId: propertyId,
            methodKey: 'custom',
            name: name,
            methodName: Value(methodName),
            siteKind: siteKind,
            cadenceDays: Value(cadenceDays),
            fieldsJson: encodeFields(fields),
            createdBy: createdBy,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return (db.select(db.protocols)..where((p) => p.id.equals(id))).getSingle();
  }

  // ---- Sites ---------------------------------------------------------

  /// Places a site. Geometry is derived from the kind: a point, a line
  /// from the origin along the bearing, or a circle. The zone is found by
  /// point-in-polygon like any record. Due today, so it shows up at once.
  Future<ProtocolSite> createSite({
    required Protocol protocol,
    required String name,
    required double lat,
    required double lng,
    double? gpsAccuracyM,
    double? bearingDeg,
    double? lengthM,
    double? radiusM,
    String? marker,
    String? photoPointId,
    int? cadenceDays,
    String? notes,
    String createdBy = 'local',
  }) async {
    final template = templateFor(protocol.methodKey);
    final length = lengthM ?? template?.defaultLengthM;
    final radius = radiusM ?? template?.defaultRadiusM;
    final bearing = bearingDeg ?? (protocol.siteKind == 'line' ? 0.0 : null);
    final geojson = siteGeojson(
      kind: protocol.siteKind,
      lat: lat,
      lng: lng,
      bearingDeg: bearing,
      lengthM: length,
      radiusM: radius,
    );
    final zoneId = await ZoneAssigner(db)
        .zoneIdFor(propertyId: protocol.propertyId, lat: lat, lng: lng);
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.protocolSites)
        .insert(
          ProtocolSitesCompanion.insert(
            id: id,
            propertyId: protocol.propertyId,
            protocolId: protocol.id,
            zoneId: Value(zoneId),
            photoPointId: Value(photoPointId),
            name: name,
            lat: lat,
            lng: lng,
            gpsAccuracyM: Value(gpsAccuracyM),
            bearingDeg: Value(bearing),
            lengthM: Value(length),
            radiusM: Value(radius),
            geojson: Value(geojson),
            marker: Value(marker),
            cadenceDays: Value(cadenceDays),
            nextDueOn: Value(_dateOnly(DateTime.now())),
            notes: Value(notes),
            createdBy: createdBy,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return (db.select(
      db.protocolSites,
    )..where((s) => s.id.equals(id))).getSingle();
  }

  Future<List<ProtocolSite>> sitesFor(
    String propertyId, {
    bool includeRetired = false,
  }) {
    final q = db.select(db.protocolSites)
      ..where((s) => s.propertyId.equals(propertyId))
      ..where((s) => s.deletedAt.isNull())
      ..orderBy([(s) => OrderingTerm.asc(s.name)]);
    if (!includeRetired) q.where((s) => s.retiredOn.isNull());
    return q.get();
  }

  /// Sites past their due date, soonest-overdue first. A retired site is
  /// never due.
  Future<List<ProtocolSite>> dueSites(
    String propertyId, {
    DateTime? today,
  }) async {
    final cutoff = _dateOnly(today ?? DateTime.now());
    return (db.select(db.protocolSites)
          ..where((s) => s.propertyId.equals(propertyId))
          ..where((s) => s.deletedAt.isNull())
          ..where((s) => s.retiredOn.isNull())
          ..where((s) => s.nextDueOn.isSmallerOrEqualValue(cutoff))
          ..orderBy([(s) => OrderingTerm.asc(s.nextDueOn)]))
        .get();
  }

  Future<void> retireSite(String siteId, {bool retired = true}) =>
      (db.update(db.protocolSites)..where((s) => s.id.equals(siteId))).write(
        ProtocolSitesCompanion(
          retiredOn: Value(retired ? _dateOnly(DateTime.now()) : null),
          updatedAt: Value(nowUtcIso()),
        ),
      );

  // ---- Runs ----------------------------------------------------------

  /// Saves one visit: the observation row first (the record), then the
  /// run, then the site's next due date rolls forward — unless the run is
  /// partial, in which case the site stays due. One transaction.
  Future<ProtocolRun> saveRun({
    required Protocol protocol,
    required ProtocolSite site,
    required Map<String, dynamic> values,
    required double? actualLat,
    required double? actualLng,
    double? gpsAccuracyM,
    DateTime? startedAt,
    DateTime? endedAt,
    String? observerName,
    String? notes,
    String status = 'complete',
    String? trackId,
    String createdBy = 'local',
  }) async {
    final started = (startedAt ?? DateTime.now()).toUtc();
    final now = nowUtcIso();
    final obsId = newId();
    final runId = newId();
    // Where the phone stood. Without a fix the record sits on the site
    // itself and says so, never at (0,0) (spec: unlocated flag).
    final located = actualLat != null && actualLng != null;
    await db.transaction(() async {
      await db
          .into(db.observations)
          .insert(
            ObservationsCompanion.insert(
              id: obsId,
              propertyId: site.propertyId,
              zoneId: Value(site.zoneId),
              observedAt: started.toIso8601String(),
              localTz: localTzName(),
              lat: located ? actualLat : site.lat,
              lng: located ? actualLng : site.lng,
              gpsAccuracyM: Value(located ? gpsAccuracyM : -1),
              observationType: const Value('survey'),
              notes: Value(notes),
              createdBy: createdBy,
              createdAt: now,
              updatedAt: now,
            ),
          );
      if (located) {
        await assignZone(
          db,
          observationId: obsId,
          propertyId: site.propertyId,
          lat: actualLat,
          lng: actualLng,
        );
      }
      await db
          .into(db.protocolRuns)
          .insert(
            ProtocolRunsCompanion.insert(
              id: runId,
              propertyId: site.propertyId,
              protocolId: protocol.id,
              siteId: site.id,
              observationId: obsId,
              startedAt: started.toIso8601String(),
              endedAt: Value(endedAt?.toUtc().toIso8601String()),
              localTz: localTzName(),
              observerName: Value(observerName),
              status: Value(status),
              valuesJson: jsonEncode(values),
              trackId: Value(trackId),
              createdBy: createdBy,
              createdAt: now,
              updatedAt: now,
            ),
          );
      if (status == 'complete') {
        final cadence = site.cadenceDays ?? protocol.cadenceDays;
        await (db.update(
          db.protocolSites,
        )..where((s) => s.id.equals(site.id))).write(
          ProtocolSitesCompanion(
            nextDueOn: Value(
              cadence == null
                  ? null
                  : _dateOnly(started.toLocal().add(Duration(days: cadence))),
            ),
            updatedAt: Value(now),
          ),
        );
      }
    });
    return (db.select(
      db.protocolRuns,
    )..where((r) => r.id.equals(runId))).getSingle();
  }

  Future<List<ProtocolRun>> runsFor(String siteId) =>
      (db.select(db.protocolRuns)
            ..where((r) => r.siteId.equals(siteId))
            ..where((r) => r.deletedAt.isNull())
            ..orderBy([(r) => OrderingTerm.desc(r.startedAt)]))
          .get();

  Future<ProtocolRun?> lastRun(String siteId) async =>
      (await (db.select(db.protocolRuns)
                ..where((r) => r.siteId.equals(siteId))
                ..where((r) => r.deletedAt.isNull())
                ..orderBy([(r) => OrderingTerm.desc(r.startedAt)])
                ..limit(1))
              .get())
          .firstOrNull;

  Future<ProtocolRun?> runForObservation(String observationId) =>
      (db.select(db.protocolRuns)
            ..where((r) => r.observationId.equals(observationId))
            ..where((r) => r.deletedAt.isNull()))
          .getSingleOrNull();

  /// Answers, as a map, or empty when the JSON is unreadable.
  static Map<String, dynamic> valuesOf(ProtocolRun run) {
    try {
      return (jsonDecode(run.valuesJson) as Map).cast<String, dynamic>();
    } catch (_) {
      return const {};
    }
  }

  Future<List<Indicator>> indicatorsFor(
    Protocol protocol,
    ProtocolSite site,
    ProtocolRun run,
  ) async {
    final names = await _taxonNames();
    return computeIndicators(
      methodKey: protocol.methodKey,
      valuesJson: run.valuesJson,
      siteKind: protocol.siteKind,
      radiusM: site.radiusM,
      lengthM: site.lengthM,
      nameOf: (id) => names[id] ?? id,
    );
  }

  Future<Map<String, String>> _taxonNames() async {
    final rows = await db.select(db.taxa).get();
    return {for (final t in rows) t.id: t.commonName ?? t.scientificName};
  }

  /// Which required answers are missing, as lay sentences ("Needs a
  /// bare-dirt pick in frame 2"). Empty means the run can be complete.
  static List<String> missingRequired(
    List<FieldDef> fields,
    Map<String, dynamic> values,
  ) {
    final out = <String>[];
    for (final f in fields) {
      if (f.type == FieldType.group) {
        final samples = values[f.key];
        final list = samples is List ? samples : const [];
        final expected = f.repeat;
        if (expected != null && list.length < expected) {
          out.add(
            '${expected - list.length} of $expected ${f.label.toLowerCase()}s still to do',
          );
        }
        for (var i = 0; i < list.length; i++) {
          final s = list[i];
          if (s is! Map) continue;
          for (final sub in f.requiredFields) {
            if (_empty(s[sub.key])) {
              out.add(
                'Needs ${sub.label.toLowerCase()} in ${f.label.toLowerCase()} ${i + 1}',
              );
            }
          }
        }
      } else if (f.required && _empty(values[f.key])) {
        out.add('Needs ${f.label.toLowerCase()}');
      }
    }
    return out;
  }

  static bool _empty(Object? v) =>
      v == null ||
      (v is String && v.trim().isEmpty) ||
      (v is List && v.isEmpty);
}

String _dateOnly(DateTime d) {
  final l = d.toLocal();
  return '${l.year.toString().padLeft(4, '0')}-'
      '${l.month.toString().padLeft(2, '0')}-'
      '${l.day.toString().padLeft(2, '0')}';
}

/// GeoJSON for a site: Point, a LineString from the origin along the
/// bearing, or a 32-gon circle. Small enough to do on a sphere.
String siteGeojson({
  required String kind,
  required double lat,
  required double lng,
  double? bearingDeg,
  double? lengthM,
  double? radiusM,
}) {
  List<double> project(double distM, double brgDeg) {
    const r = 6371000.0;
    final brg = brgDeg * math.pi / 180;
    final lat1 = lat * math.pi / 180;
    final lng1 = lng * math.pi / 180;
    final d = distM / r;
    final lat2 = math.asin(
      math.sin(lat1) * math.cos(d) +
          math.cos(lat1) * math.sin(d) * math.cos(brg),
    );
    final lng2 =
        lng1 +
        math.atan2(
          math.sin(brg) * math.sin(d) * math.cos(lat1),
          math.cos(d) - math.sin(lat1) * math.sin(lat2),
        );
    return [
      double.parse((lng2 * 180 / math.pi).toStringAsFixed(7)),
      double.parse((lat2 * 180 / math.pi).toStringAsFixed(7)),
    ];
  }

  switch (kind) {
    case 'line':
    case 'route':
      if (lengthM == null || lengthM <= 0) break;
      final end = project(lengthM, bearingDeg ?? 0);
      return jsonEncode({
        'type': 'LineString',
        'coordinates': [
          [lng, lat],
          end,
        ],
      });
    case 'plot':
      if (radiusM == null || radiusM <= 0) break;
      final ring = [
        for (var i = 0; i < 32; i++) project(radiusM, i * 360 / 32),
      ];
      ring.add(ring.first);
      return jsonEncode({
        'type': 'Polygon',
        'coordinates': [ring],
      });
  }
  return jsonEncode({
    'type': 'Point',
    'coordinates': [lng, lat],
  });
}
