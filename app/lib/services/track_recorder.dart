import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/database.dart';
import '../geo/simplify.dart';
import 'location_hub.dart';

/// Track logging (spec §4.13): 5 s / 10 m sampling behind an Android
/// foreground service with a persistent notification. Raw points are kept for
/// the active track only; Douglas-Peucker (~5 m) runs on save.
///
/// Positions come from [LocationHub] — the only owner of the platform stream —
/// which is switched into foreground mode for the life of the track so the
/// service / wake-lock settings actually reach the OS.
class TrackRecorder extends ChangeNotifier {
  TrackRecorder(this.db, this.hub);

  final FieldNotesDb db;
  final LocationHub hub;

  /// Fixes worse than this are cold-start noise, not a walk.
  static const maxAccuracyM = 30.0;

  String? _trackId;
  String? _propertyId;
  StreamSubscription<Position>? _sub;
  final List<List<double>> _points = []; // (lng, lat)
  DateTime? _startedAt;
  int _skipped = 0;

  bool get recording => _trackId != null;
  int get pointCount => _points.length;
  int get skippedCount => _skipped;
  double get distanceSoFarM => pathLengthM(_points);
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  /// Surfaced in the UI — a silently dead stream would look like a working
  /// recorder that logs nothing.
  String? lastError;

  bool _starting = false;

  Future<void> start(String propertyId, {String? purpose}) async {
    if (recording || _starting) return;
    _starting = true;
    try {
      lastError = null;
      if (!await hub.ensurePermission()) {
        lastError = 'Location permission needed to log a track';
        notifyListeners();
        return;
      }
      // Android 13+: the foreground service runs without this, but its
      // "recording your walk" notification is invisible — and so is the
      // only out-of-app way to notice the GPS is on. Ask; never block on it.
      try {
        await Permission.notification.request();
      } catch (_) {}
      final now = nowUtcIso();
      final id = newId();
      await db.into(db.tracks).insert(TracksCompanion.insert(
            id: id,
            propertyId: propertyId,
            startedAt: now,
            purpose: Value(purpose),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ));
      _trackId = id;
      _propertyId = propertyId;
      _points.clear();
      _skipped = 0;
      _startedAt = DateTime.now();

      _sub = hub.positions.listen(_onPosition);
      // The hub owns recovery; we own telling the user. A dead GPS during a
      // walk must show on the toggle, not sit at 0.0 km looking busy.
      hub.addListener(_onHubChanged);
      await hub.setForeground(true);
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  void _onHubChanged() {
    if (!recording) return;
    final err = hub.lastError;
    if (err != lastError) {
      lastError = err == null ? null : 'GPS lost — $err';
      notifyListeners();
    }
  }

  Future<void> _onPosition(Position pos) async {
    final trackId = _trackId;
    if (trackId == null) return;
    if (pos.accuracy > maxAccuracyM) {
      _skipped++;
      notifyListeners();
      return;
    }
    _points.add([pos.longitude, pos.latitude]);
    await db.into(db.trackPoints).insert(TrackPointsCompanion.insert(
          id: newId(),
          trackId: trackId,
          recordedAt: nowUtcIso(),
          lat: pos.latitude,
          lng: pos.longitude,
          accuracyM: Value(pos.accuracy),
          altitudeM: Value(pos.altitude),
          speedMps: Value(pos.speed),
        ));
    notifyListeners();
  }

  Future<void> stop() async {
    final trackId = _trackId;
    if (trackId == null) return;
    await _sub?.cancel();
    _sub = null;
    hub.removeListener(_onHubChanged);
    await hub.setForeground(false);

    await _finalize(trackId, List.of(_points));

    _trackId = null;
    _propertyId = null;
    _points.clear();
    _startedAt = null;
    notifyListeners();
  }

  /// Tracks left open by a killed process: rebuild the line from the
  /// persisted raw points and close them out. Call once at startup.
  Future<int> recoverOpenTracks() async {
    final open = await (db.select(db.tracks)
          ..where((t) => t.endedAt.isNull() & t.deletedAt.isNull()))
        .get();
    for (final t in open) {
      final rows = await (db.select(db.trackPoints)
            ..where((p) => p.trackId.equals(t.id))
            ..orderBy([(p) => OrderingTerm.asc(p.recordedAt)]))
          .get();
      if (rows.isEmpty) {
        // Never got a fix: not a walk. Tombstone rather than keep an empty
        // track in the ledger.
        final now = nowUtcIso();
        await (db.update(db.tracks)..where((x) => x.id.equals(t.id))).write(
            TracksCompanion(deletedAt: Value(now), updatedAt: Value(now)));
        continue;
      }
      await _finalize(t.id, [for (final r in rows) [r.lng, r.lat]],
          endedAt: rows.last.recordedAt);
    }
    return open.length;
  }

  Future<void> _finalize(String trackId, List<List<double>> points,
      {String? endedAt}) async {
    final now = nowUtcIso();
    final simplified = simplifyTrack(points);
    await (db.update(db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        endedAt: Value(endedAt ?? now),
        distanceM: Value(pathLengthM(points)),
        geojson: Value(simplified.length >= 2
            ? jsonEncode(
                {'type': 'LineString', 'coordinates': simplified})
            : null),
        updatedAt: Value(now),
      ),
    );
    // Raw points served their purpose; the simplified line is the record
    // (D-008).
    await (db.delete(db.trackPoints)
          ..where((p) => p.trackId.equals(trackId)))
        .go();
  }

  String? get activePropertyId => _propertyId;
}
