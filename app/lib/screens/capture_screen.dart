import 'dart:async';

import 'package:camera/camera.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/database.dart';
import '../geo/zone_assignment.dart';
import '../services/media_store.dart';
import '../widgets/species_field.dart';

/// Capture flow (spec §7.2): camera → auto GPS/time/zone → species → notes →
/// save. Everything after the photo is optional, and a save never blocks on
/// network, GPS lock, or species ID.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  CameraController? _camera;
  String? _cameraError;
  XFile? _shot;

  Position? _fix;
  StreamSubscription<Position>? _fixSub;

  TaxaData? _taxon;
  final _notesController = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _initLocation();
  }

  bool _cameraPermanentlyDenied = false;

  Future<void> _initCamera() async {
    try {
      // The camera plugin does not reliably prompt on all devices — request
      // explicitly before touching the controller.
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        setState(() {
          _cameraPermanentlyDenied = status.isPermanentlyDenied;
          _cameraError = 'Camera permission needed to attach photos';
        });
        return;
      }
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraError = 'No camera available');
        return;
      }
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() => _camera = controller);
    } catch (e) {
      if (mounted) setState(() => _cameraError = '$e');
    }
  }

  Future<void> _initLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return; // record saves without coordinates rather than blocking
      }
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) setState(() => _fix = last);
      _fixSub = Geolocator.getPositionStream(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.best),
      ).listen((pos) {
        if (mounted) setState(() => _fix = pos);
      });
    } catch (_) {
      // GPS problems never block capture
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    _fixSub?.cancel();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    final shot = await camera.takePicture();
    setState(() => _shot = shot);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final db = widget.db;
    final now = nowUtcIso();
    final fix = _fix;
    final obsId = newId();

    // No fix and no property centroid → hold the save until either arrives is
    // forbidden (never block on GPS), so fall back to centroid; if even that
    // is missing, flag the row via gps_accuracy_m = -1 rather than writing a
    // silent (0,0) that looks like a real coordinate off the coast of Africa.
    final lat = fix?.latitude ?? widget.property.centroidLat;
    final lng = fix?.longitude ?? widget.property.centroidLng;
    final unlocated = lat == null || lng == null;

    await db.into(db.observations).insert(ObservationsCompanion.insert(
          id: obsId,
          propertyId: widget.property.id,
          observedAt: now,
          localTz: localTzName(),
          lat: lat ?? 0,
          lng: lng ?? 0,
          gpsAccuracyM: Value(unlocated ? -1 : fix?.accuracy),
          altitudeM: Value(fix?.altitude),
          headingDeg: Value(fix?.heading),
          observationType: Value(_taxon != null ? 'plant' : 'general'),
          taxonId: Value(_taxon?.id),
          taxonConfidence: Value(_taxon != null ? 'certain' : null),
          notes: Value(
              _notesController.text.trim().isEmpty ? null : _notesController.text.trim()),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));

    if (fix != null) {
      await assignZone(db,
          observationId: obsId,
          propertyId: widget.property.id,
          lat: fix.latitude,
          lng: fix.longitude);
    }

    final shot = _shot;
    if (shot != null) {
      final media = await MediaStore(db).savePhoto(
        await shot.readAsBytes(),
        propertyId: widget.property.id,
        createdBy: 'local',
        lat: fix?.latitude,
        lng: fix?.longitude,
        headingDeg: fix?.heading,
        capturedAt: now,
      );
      await MediaStore(db).linkTo(
        media.id,
        propertyId: widget.property.id,
        entityType: 'observation',
        entityId: obsId,
        role: 'primary',
      );
    }

    if (mounted) Navigator.of(context).pop(obsId);
  }

  @override
  Widget build(BuildContext context) {
    return _shot == null ? _buildCamera() : _buildForm();
  }

  Widget _buildCamera() {
    final camera = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('New record'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _shot = XFile('')),
            child: const Text('Skip photo',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _cameraError != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_cameraError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70)),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () async {
                            if (_cameraPermanentlyDenied) {
                              await openAppSettings();
                            } else {
                              setState(() => _cameraError = null);
                              await _initCamera();
                            }
                          },
                          child: Text(_cameraPermanentlyDenied
                              ? 'Open settings'
                              : 'Grant camera access'),
                        ),
                      ],
                    ),
                  )
                : camera == null
                    ? const Center(child: CircularProgressIndicator())
                    : CameraPreview(camera),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: FloatingActionButton.large(
                onPressed: _takePhoto,
                child: const Icon(Icons.camera_alt, size: 36),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    final fix = _fix;
    final hasPhoto = _shot != null && _shot!.path.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('New record')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Chip(
                avatar: Icon(
                  fix == null ? Icons.gps_off : Icons.gps_fixed,
                  size: 18,
                ),
                label: Text(fix == null
                    ? 'No GPS fix — saving anyway'
                    : '±${fix.accuracy.toStringAsFixed(0)} m'),
              ),
              const SizedBox(width: 8),
              if (hasPhoto) const Chip(label: Text('Photo attached')),
            ],
          ),
          const SizedBox(height: 12),
          SpeciesField(
            db: widget.db,
            onSelected: (t) => setState(() => _taxon = t),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notesController,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Notes',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check),
              label: Text(_saving ? 'Saving…' : 'Save record'),
            ),
          ),
        ],
      ),
    );
  }
}
