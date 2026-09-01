import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../db/database.dart';
import '../../geo/simplify.dart' show distanceM;
import '../../main.dart' show locationHub;
import '../../services/compass.dart';
import '../../services/media_store.dart';

/// Ghost-overlay capture (spec §4.9, required): reference frame at ~35%
/// opacity over the live preview, with bearing and distance readouts. Green
/// when within 3 m and 5°.
class GhostCaptureScreen extends StatefulWidget {
  const GhostCaptureScreen({super.key, required this.db, required this.point});

  final FieldNotesDb db;
  final PhotoPoint point;

  @override
  State<GhostCaptureScreen> createState() => _GhostCaptureScreenState();
}

class _GhostCaptureScreenState extends State<GhostCaptureScreen> {
  CameraController? _camera;
  String? _error;
  String? _referencePath;
  bool _isFirstVisit = false;

  Position? _fix;
  double? _heading;
  StreamSubscription<Position>? _fixSub;
  CompassStream? _compass;
  StreamSubscription<double>? _headingSub;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Reference frame for the overlay.
    final refId = widget.point.referenceMediaId;
    if (refId == null) {
      _isFirstVisit = true;
    } else {
      final media = await (widget.db.select(
        widget.db.media,
      )..where((m) => m.id.equals(refId))).getSingleOrNull();
      final path = media?.localPath;
      if (path != null && File(path).existsSync()) {
        _referencePath = path;
      } else {
        _isFirstVisit = true;
      }
    }

    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() => _error = 'Camera permission needed');
      return;
    }
    try {
      final cameras = await availableCameras();
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }

    final located = await locationHub.ensurePermission();
    if (!mounted) return;
    if (located) {
      final last = locationHub.fresh();
      if (last != null) setState(() => _fix = last);
      _fixSub = locationHub.positions.listen((pos) {
        if (mounted) setState(() => _fix = pos);
      });
    }
    _compass = CompassStream();
    _headingSub = _compass!.headingDeg.listen((h) {
      if (mounted) setState(() => _heading = h);
    });
  }

  @override
  void dispose() {
    _camera?.dispose();
    _fixSub?.cancel();
    _headingSub?.cancel();
    _compass?.dispose();
    super.dispose();
  }

  double? get _distanceM {
    final fix = _fix;
    if (fix == null || _isFirstVisit) return null;
    return distanceM(
      [fix.longitude, fix.latitude],
      [widget.point.lng, widget.point.lat],
    );
  }

  double? get _bearingOffDeg {
    final h = _heading;
    if (h == null || _isFirstVisit) return null;
    return angleDiffDeg(widget.point.bearingDeg, h);
  }

  bool get _aligned {
    final d = _distanceM;
    final b = _bearingOffDeg;
    return d != null && b != null && d <= 3 && b.abs() <= 5;
  }

  /// A first visit anchors the point for good (D-007), so it needs a real
  /// position AND a real heading; without both the point would sit at the
  /// centroid facing north forever and never line up (audit M14).
  bool get _anchorReady => !_isFirstVisit || (_fix != null && _heading != null);

  /// What the first visit is still waiting on, or null when ready.
  String? get _anchorWaiting {
    if (!_isFirstVisit) return null;
    if (_fix == null && _heading == null) return 'waiting for GPS and compass…';
    if (_fix == null) return 'waiting for GPS…';
    if (_heading == null) return 'waiting for compass…';
    return null;
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _saving) return;
    if (!_anchorReady) return;
    setState(() => _saving = true);
    try {
      await _captureInner(camera);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Capture failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _captureInner(CameraController camera) async {
    // Re-checked here so a fix/heading that vanished between the tap and
    // the shutter can never anchor the point from a null.
    final fix = _fix;
    final heading = _heading;
    if (_isFirstVisit && (fix == null || heading == null)) {
      throw StateError('Need a GPS fix and a compass heading to anchor');
    }
    final shot = await camera.takePicture();
    final now = nowUtcIso();
    final db = widget.db;
    final point = widget.point;

    final bytes = await shot.readAsBytes();
    try {
      File(shot.path).deleteSync();
    } catch (_) {}
    final media = await MediaStore(db).savePhoto(
      bytes,
      propertyId: point.propertyId,
      createdBy: 'local',
      lat: fix?.latitude,
      lng: fix?.longitude,
      headingDeg: heading,
      capturedAt: now,
    );

    final visitId = newId();
    await db
        .into(db.photoPointVisits)
        .insert(
          PhotoPointVisitsCompanion.insert(
            id: visitId,
            propertyId: point.propertyId,
            photoPointId: point.id,
            visitedAt: now,
            actualLat: Value(fix?.latitude),
            actualLng: Value(fix?.longitude),
            actualBearingDeg: Value(heading),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await MediaStore(db).linkTo(
      media.id,
      propertyId: point.propertyId,
      entityType: 'photo_point_visit',
      entityId: visitId,
      role: _isFirstVisit ? 'reference' : 'attachment',
    );

    // First visit anchors the point: reference frame, true position and
    // bearing — all three together, or none (fix/heading were checked above).
    final anchor = _isFirstVisit && fix != null && heading != null;
    final updates = PhotoPointsCompanion(
      updatedAt: Value(now),
      nextDueOn: point.cadenceDays != null
          ? Value(
              DateTime.now()
                  .add(Duration(days: point.cadenceDays!))
                  .toIso8601String()
                  .substring(0, 10),
            )
          : const Value.absent(),
      referenceMediaId: anchor ? Value(media.id) : const Value.absent(),
      lat: anchor ? Value(fix.latitude) : const Value.absent(),
      lng: anchor ? Value(fix.longitude) : const Value.absent(),
      bearingDeg: anchor ? Value(heading) : const Value.absent(),
    );
    await (db.update(
      db.photoPoints,
    )..where((p) => p.id.equals(point.id))).write(updates);

    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isFirstVisit
                ? 'Photo point anchored — this frame is the reference'
                : 'Visit captured',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final distance = _distanceM;
    final bearingOff = _bearingOffDeg;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.point.name),
      ),
      body: _error != null
          ? Center(
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.white70),
              ),
            )
          : camera == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(camera),
                      if (_referencePath != null)
                        Opacity(
                          opacity: 0.35,
                          child: Image.file(
                            File(_referencePath!),
                            fit: BoxFit.cover,
                          ),
                        ),
                      Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: _isFirstVisit
                            ? _readout(
                                _anchorWaiting != null
                                    ? 'First visit — ${_anchorWaiting!} '
                                          'Position and bearing are needed '
                                          'to anchor the point.'
                                    : 'First visit — aim at the subject '
                                          'and capture. This anchors the '
                                          'point.',
                                _anchorWaiting != null
                                    ? Colors.black54
                                    : Colors.blueGrey.shade700,
                              )
                            : _readout(
                                '${distance == null ? '— m' : '${distance.toStringAsFixed(1)} m'} from point   ·   '
                                '${bearingOff == null ? '—°' : '${bearingOff > 0 ? '+' : ''}${bearingOff.toStringAsFixed(0)}°'} off bearing',
                                _aligned
                                    ? Colors.green.shade700
                                    : Colors.black54,
                              ),
                      ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: FloatingActionButton.large(
                      backgroundColor: _aligned ? Colors.green.shade600 : null,
                      onPressed: _saving || !_anchorReady ? null : _capture,
                      child: const Icon(Icons.camera_alt, size: 36),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _readout(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
