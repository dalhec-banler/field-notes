import 'dart:async';

import 'package:camera/camera.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/database.dart';
import '../geo/zone_assignment.dart';
import '../services/env_context.dart';
import '../services/media_store.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import '../widgets/species_field.dart';

/// Result handed back to the shell for the save toast.
class CaptureResult {
  CaptureResult(this.observationId, this.elapsed);
  final String observationId;
  final Duration elapsed;
}

/// Capture (design README §3.8): the flow the whole app is built around.
/// Camera-dark full-screen modal; save is never blocked on GPS, network, or
/// identification; a record without a photograph is a legitimate record.
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
  bool _cameraPermanentlyDenied = false;
  XFile? _shot;
  int _step = 0; // 0 shutter · 1 form · 2 notes

  Position? _fix;
  StreamSubscription<Position>? _fixSub;

  TaxaData? _taxon;
  String _observationType = 'general';
  final _notesController = TextEditingController();
  bool _saving = false;

  static const _types = [
    'general', 'plant', 'wildlife', 'problem', 'water', 'soil',
    'phenology', 'sign', 'weather', 'maintenance'
  ];

  @override
  void initState() {
    super.initState();
    _initCamera();
    _initLocation();
  }

  Future<void> _initCamera() async {
    try {
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
    setState(() {
      _shot = shot;
      _step = 1;
    });
  }

  void _noPhoto() => setState(() => _step = 1);

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final started = DateTime.now();
    final db = widget.db;
    final now = nowUtcIso();
    final fix = _fix;
    final obsId = newId();

    final lat = fix?.latitude ?? widget.property.centroidLat;
    final lng = fix?.longitude ?? widget.property.centroidLng;
    final unlocated = lat == null || lng == null;

    // Environmental context: created stale now, backfilled when online
    // (spec §4.11). Never blocks the save.
    String? envContextId;
    if (!unlocated) {
      final envService = EnvContextService(db);
      envContextId = await envService.createStale(
        propertyId: widget.property.id,
        lat: lat,
        lng: lng,
        resolvedFor: now.substring(0, 10),
      );
      unawaited(envService.backfillStale());
    }

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
          observationType: Value(
              _taxon != null && _observationType == 'general'
                  ? 'plant'
                  : _observationType),
          taxonId: Value(_taxon?.id),
          taxonConfidence: Value(_taxon != null ? 'certain' : null),
          notes: Value(_notesController.text.trim().isEmpty
              ? null
              : _notesController.text.trim()),
          envContextId: Value(envContextId),
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
    if (shot != null && shot.path.isNotEmpty) {
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

    if (mounted) {
      Navigator.of(context)
          .pop(CaptureResult(obsId, DateTime.now().difference(started)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Press.cameraDark,
      body: SafeArea(
        child: switch (_step) {
          0 => _buildShutter(),
          1 => _buildForm(),
          _ => _buildNotes(),
        },
      ),
    );
  }

  // Step 0 — shutter.
  Widget _buildShutter() {
    final camera = _camera;
    final fix = _fix;
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_cameraError != null)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_cameraError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontFamily: Type.serif,
                              color: Color(0xB3F4ECD8))),
                      const SizedBox(height: 14),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Press.paperRaised,
                          side: const BorderSide(
                              color: Press.paperRaised, width: 1.5),
                        ),
                        onPressed: () async {
                          if (_cameraPermanentlyDenied) {
                            await openAppSettings();
                          } else {
                            setState(() => _cameraError = null);
                            await _initCamera();
                          }
                        },
                        child: Text(_cameraPermanentlyDenied
                            ? 'OPEN SETTINGS'
                            : 'GRANT CAMERA ACCESS'),
                      ),
                    ],
                  ),
                )
              else if (camera == null)
                const Center(
                    child: CircularProgressIndicator(
                        color: Press.paperRaised))
              else
                CameraPreview(camera),
              // Scrim.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x421E2C25), Color(0x801E2C25)],
                  ),
                ),
              ),
              // Inset frame line.
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: const Color(0x66F4ECD8), width: 1.5),
                    ),
                  ),
                ),
              ),
              // Corner diamonds.
              const Positioned(
                  top: 30,
                  left: 30,
                  child: Diamond(size: 9, color: Press.sage)),
              const Positioned(
                  top: 30,
                  right: 30,
                  child: Diamond(size: 9, color: Press.sage)),
              // Focus square.
              Center(
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: const Color(0x99F4ECD8), width: 1.5),
                  ),
                ),
              ),
              // Top readout.
              Positioned(
                top: 34,
                left: 44,
                right: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const MonoLabel('◆ Ready',
                        size: 9.5, spacing: 1.8, color: Press.paperRaised),
                    MonoLabel(
                      fix == null
                          ? 'no fix — save works anyway'
                          : '±${fix.accuracy.toStringAsFixed(1)} m',
                      size: 9.5,
                      spacing: 1.4,
                      color: Press.paperRaised,
                    ),
                  ],
                ),
              ),
              // Bottom-left coordinates.
              if (fix != null)
                Positioned(
                  left: 34,
                  bottom: 34,
                  child: MonoLabel(
                    '${fix.latitude.toStringAsFixed(5)}\n${fix.longitude.toStringAsFixed(5)}',
                    size: 9.5,
                    spacing: 1.2,
                    color: Press.paperRaised,
                    opacity: 0.9,
                  ),
                ),
            ],
          ),
        ),
        // Shutter bar: Cancel · shutter · No photo — which advances exactly
        // like the shutter does.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              SizedBox(
                width: 90,
                height: 58,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('CANCEL',
                      style: TextStyle(color: Color(0x99F4ECD8))),
                ),
              ),
              GestureDetector(
                onTap: _takePhoto,
                child: Container(
                  width: Metrics.shutterSize,
                  height: Metrics.shutterSize,
                  decoration: BoxDecoration(
                    color: Press.oxblood,
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: Press.paperRaised, width: 4),
                  ),
                ),
              ),
              SizedBox(
                width: 90,
                height: 58,
                child: TextButton(
                  onPressed: _noPhoto,
                  child: const Text('NO PHOTO',
                      style: TextStyle(color: Color(0x99F4ECD8))),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Step 1 — the form.
  Widget _buildForm() {
    final fix = _fix;
    return Container(
      color: Press.paper,
      child: Column(
        children: [
          // Header strip.
          Container(
            padding: const EdgeInsets.fromLTRB(13, 10, 6, 10),
            decoration: const BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: Press.ink, width: Metrics.borderStructural)),
            ),
            child: Row(
              children: [
                const Diamond(size: 9, color: Press.sage),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MonoLabel(
                        'Captured'
                        '${fix != null ? ' · ±${fix.accuracy.toStringAsFixed(1)} m' : ' · no fix — saving anyway'}',
                        size: 9.5,
                        spacing: 1.6,
                        color: Press.sage,
                      ),
                      const SizedBox(height: 2),
                      const MonoLabel('zone · point-in-polygon · turf_dart',
                          size: 8.5, opacity: 0.65),
                    ],
                  ),
                ),
                SizedBox(
                  width: 46,
                  height: 46,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('✕'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(Metrics.gutter),
              children: [
                const MonoLabel('identification · nothing written yet',
                    size: 9, spacing: 1.8),
                const SizedBox(height: 8),
                SpeciesField(
                  db: widget.db,
                  onSelected: (t) => setState(() => _taxon = t),
                ),
                const SizedBox(height: 10),
                const RailNote(
                  color: Press.oxblood,
                  body:
                      'A machine ID is never written to taxon_id without your '
                      'acceptance. Leave it blank and confidence saves as '
                      'unidentified.',
                ),
                const SizedBox(height: 16),
                const MonoLabel('observation_type', size: 9, spacing: 1.8),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final t in _types)
                      GestureDetector(
                        onTap: () => setState(() => _observationType = t),
                        child: Container(
                          height: 46,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 13),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color:
                                _observationType == t ? Press.ink : null,
                            border: Border.all(color: Press.ink, width: 1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            t.toUpperCase(),
                            style: TextStyle(
                              fontFamily: Type.mono,
                              fontSize: 9.5,
                              letterSpacing: 1.4,
                              color: _observationType == t
                                  ? Press.paper
                                  : Press.ink,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const MonoLabel('env_context · attached, is_stale = 1',
                    size: 9, spacing: 1.8),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      color: Press.paperRaised,
                      border: Border.all(color: Press.ink, width: 1.5)),
                  child: Column(
                    children: [
                      FactRow(
                          'observed_at',
                          nowUtcIso()
                              .replaceFirst('T', ' ')
                              .substring(0, 16)),
                      FactRow(
                          'lat / lng',
                          fix != null
                              ? '${fix.latitude.toStringAsFixed(5)}, ${fix.longitude.toStringAsFixed(5)}'
                              : 'none — flagged, not faked'),
                      const FactRow(
                          'is_stale', '1 · backfills from Open-Meteo + NRCS',
                          last: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Footer.
          Container(
            padding: const EdgeInsets.all(Metrics.gutter),
            decoration: const BoxDecoration(
              border:
                  Border(top: BorderSide(color: Press.divider, width: 1)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 58,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child:
                          Text(_saving ? 'WRITING…' : 'SAVE OBSERVATION'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 58,
                  child: OutlinedButton(
                    onPressed: () => setState(() => _step = 2),
                    child: const Text('+ NOTES'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Step 2 — notes.
  Widget _buildNotes() {
    return Container(
      color: Press.paper,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(6, 10, 13, 10),
            decoration: const BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: Press.ink, width: Metrics.borderStructural)),
            ),
            child: Row(
              children: [
                SizedBox(
                  height: 46,
                  child: TextButton(
                    onPressed: () => setState(() => _step = 1),
                    child: const Text('‹ BACK'),
                  ),
                ),
                const SizedBox(width: 6),
                const MonoLabel('Notes & voice', size: 10, spacing: 1.8),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(Metrics.gutter),
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 124),
                  child: TextField(
                    controller: _notesController,
                    minLines: 5,
                    maxLines: 12,
                    cursorColor: Press.oxblood,
                    style: const TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 16.5,
                        height: 1.6),
                    decoration:
                        const InputDecoration(hintText: 'What did you see?'),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(Metrics.gutter),
            child: SizedBox(
              height: 58,
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'WRITING…' : 'SAVE OBSERVATION'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
