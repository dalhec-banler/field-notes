import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../db/database.dart';
import '../geo/simplify.dart';

/// Track logging (spec §4.13): 5 s / 10 m sampling behind an Android
/// foreground service with a persistent notification. Raw points are kept for
/// the active track only; Douglas-Peucker (~5 m) runs on save.
class TrackRecorder extends ChangeNotifier {
  TrackRecorder(this.db);

  final FieldNotesDb db;

  String? _trackId;
  String? _propertyId;
  StreamSubscription<Position>? _sub;
  final List<List<double>> _points = []; // (lng, lat)
  DateTime? _startedAt;

  bool get recording => _trackId != null;
  int get pointCount => _points.length;
  double get distanceSoFarM => pathLengthM(_points);
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  Future<void> start(String propertyId, {String? purpose}) async {
    if (recording) return;
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
    _startedAt = DateTime.now();

    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 10, // spec: 10 m minimum displacement
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Field Notes is recording your walk',
          notificationText: 'Track logging is on. Tap stop in the app.',
          notificationIcon:
              AndroidResource(name: 'launch_background', defType: 'drawable'),
          enableWakeLock: true,
        ),
      ),
    ).listen(_onPosition, onError: (Object e) {
      lastError = '$e';
      notifyListeners();
    });
    notifyListeners();
  }

  /// Surfaced in the UI — a silently dead stream would look like a working
  /// recorder that logs nothing.
  String? lastError;

  Future<void> _onPosition(Position pos) async {
    final trackId = _trackId;
    if (trackId == null) return;
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

    final now = nowUtcIso();
    final simplified = simplifyTrack(List.of(_points));
    await (db.update(db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        endedAt: Value(now),
        distanceM: Value(pathLengthM(_points)),
        geojson: Value(simplified.length >= 2
            ? jsonEncode(
                {'type': 'LineString', 'coordinates': simplified})
            : null),
        updatedAt: Value(now),
      ),
    );
    // Raw points served their purpose; the simplified line is the record.
    await (db.delete(db.trackPoints)
          ..where((p) => p.trackId.equals(trackId)))
        .go();

    _trackId = null;
    _propertyId = null;
    _points.clear();
    _startedAt = null;
    notifyListeners();
  }

  String? get activePropertyId => _propertyId;
}
