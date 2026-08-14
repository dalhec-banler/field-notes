import 'dart:async';

import 'package:camera/camera.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../db/database.dart';
import '../geo/zone_assignment.dart';
import '../services/media_store.dart';

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
  final _speciesController = TextEditingController();
  final _notesController = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _initLocation();
  }

  Future<void> _initCamera() async {
    try {
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
    _speciesController.dispose();
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

    await db.into(db.observations).insert(ObservationsCompanion.insert(
          id: obsId,
          propertyId: widget.property.id,
          observedAt: now,
          localTz: localTzName(),
          lat: fix?.latitude ?? widget.property.centroidLat ?? 0,
          lng: fix?.longitude ?? widget.property.centroidLng ?? 0,
          gpsAccuracyM: Value(fix?.accuracy),
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
                    child: Text('Camera unavailable\n$_cameraError',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70)))
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
          _SpeciesField(
            db: widget.db,
            controller: _speciesController,
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

class _SpeciesField extends StatefulWidget {
  const _SpeciesField({
    required this.db,
    required this.controller,
    required this.onSelected,
  });

  final FieldNotesDb db;
  final TextEditingController controller;
  final ValueChanged<TaxaData?> onSelected;

  @override
  State<_SpeciesField> createState() => _SpeciesFieldState();
}

class _SpeciesFieldState extends State<_SpeciesField> {
  List<TaxaData> _suggestions = const [];

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _suggestions = const []);
      widget.onSelected(null);
      return;
    }
    final q = '%${query.trim()}%';
    final rows = await (widget.db.select(widget.db.taxa)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.commonName.like(q) |
                  t.scientificName.like(q) |
                  t.family.like(q)))
          ..orderBy([
            (t) => OrderingTerm.desc(t.isFavorite),
            (t) => OrderingTerm.asc(t.scientificName),
          ])
          ..limit(10))
        .get();
    if (mounted) setState(() => _suggestions = rows);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          onChanged: _search,
          decoration: const InputDecoration(
            labelText: 'Species (optional)',
            prefixIcon: Icon(Icons.local_florist_outlined),
            border: OutlineInputBorder(),
          ),
        ),
        for (final t in _suggestions)
          ListTile(
            minTileHeight: 48,
            dense: true,
            leading: t.isFavorite == 1
                ? const Icon(Icons.star, size: 18)
                : const SizedBox(width: 18),
            title: Text(t.commonName ?? t.scientificName),
            subtitle: Text(t.scientificName),
            onTap: () {
              widget.controller.text = t.commonName ?? t.scientificName;
              widget.onSelected(t);
              setState(() => _suggestions = const []);
            },
          ),
      ],
    );
  }
}
