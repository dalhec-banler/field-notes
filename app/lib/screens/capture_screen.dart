import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/database.dart';
import '../geo/zone_assignment.dart';
import '../main.dart' show locationHub;
import '../services/env_context.dart';
import '../services/media_store.dart';
import '../services/observation_ops.dart';
import '../services/voice_note.dart';
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
  CaptureScreen({
    super.key,
    required this.db,
    required this.property,
    this.placedLat,
    this.placedLng,
  });

  final FieldNotesDb db;
  final Property property;

  /// Set when the record was dropped by long-pressing the map (spec §7.1):
  /// the location is the pressed point, not the phone's fix.
  final double? placedLat;
  final double? placedLng;

  bool get isPlaced => placedLat != null && placedLng != null;

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
  /// True only once a fix has arrived from the live stream this session.
  /// A last-known hint is displayed but never written as a location.
  bool _fixIsLive = false;
  StreamSubscription<Position>? _fixSub;

  TaxaData? _taxon;
  String _observationType = 'general';
  final _notesController = TextEditingController();
  bool _saving = false;

  /// Voice note (spec §7.2): audio kept, transcript appended to notes.
  final _voice = VoiceNoteRecorder();
  String? _voicePath;
  int? _voiceMs;

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
      if (!mounted) {
        // Cancelled while the camera was spinning up: release it, or the
        // next capture opens to "camera in use".
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (e) {
      if (mounted) setState(() => _cameraError = '$e');
    }
  }

  Future<void> _initLocation() async {
    try {
      if (!await locationHub.ensurePermission()) {
        return; // record saves without coordinates rather than blocking
      }
      if (!mounted) return;
      // A fix from before the app idled is not a fix. The OS's last-known
      // position is shown as a hint until the live stream delivers, but
      // only a LIVE fix is ever written — see _fixIsLive in _save.
      final fresh = locationHub.fresh();
      if (fresh != null) {
        if (mounted) {
          setState(() {
            _fix = fresh;
            _fixIsLive = true;
          });
        }
      } else {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null &&
            DateTime.now().difference(last.timestamp) <
                Duration(minutes: 2) &&
            mounted) {
          setState(() => _fix = last);
        }
      }
      _fixSub = locationHub.positions.listen((pos) {
        if (mounted) {
          setState(() {
            _fix = pos;
            _fixIsLive = true;
          });
        }
      });
    } catch (_) {
      // GPS problems never block capture
    }
  }

  /// Name of the zone under the current fix, resolved when the form opens
  /// so the header can say where you are in words.
  String? _zoneName;
  bool _zoneResolved = false;

  Future<void> _resolveZone() async {
    final fix = _fix;
    if (fix == null) {
      setState(() {
        _zoneName = null;
        _zoneResolved = true;
      });
      return;
    }
    try {
      final zoneId = await ZoneAssigner(widget.db).zoneIdFor(
          propertyId: widget.property.id,
          lat: fix.latitude,
          lng: fix.longitude);
      Zone? zone;
      if (zoneId != null) {
        zone = await (widget.db.select(widget.db.zones)
              ..where((z) => z.id.equals(zoneId)))
            .getSingleOrNull();
      }
      if (mounted) {
        setState(() {
          _zoneName = zone?.name;
          _zoneResolved = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _zoneResolved = true);
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    _fixSub?.cancel();
    _notesController.dispose();
    _discardShotFile();
    // Orderly stop → dispose so a half-written recording is never left in
    // the cache; an unsaved one is discarded.
    if (!_voiceSaved) _voice.discard(_voicePath);
    _voice.shutdown(discardRecording: !_voiceSaved);
    super.dispose();
  }

  bool _voiceSaved = false;

  /// Mic button: tap to start, tap to stop. The transcript lands in the
  /// notes field as it's recognised; the audio is kept regardless.
  Future<void> _toggleVoice() async {
    if (_voice.recording) {
      final path = await _voice.stop();
      if (!mounted) return;
      setState(() {
        _voicePath = path;
        _voiceMs = path == null ? null : _voice.lastDuration.inMilliseconds;
      });
      final text = _voice.transcript.trim();
      if (text.isNotEmpty) {
        final existing = _notesController.text.trimRight();
        _notesController.text =
            existing.isEmpty ? text : '$existing\n$text';
        _notesController.selection = TextSelection.collapsed(
            offset: _notesController.text.length);
      }
      return;
    }
    // A second recording replaces the first (one voice note per record).
    if (_voicePath != null) {
      await _voice.discard(_voicePath);
      _voicePath = null;
    }
    final ok = await _voice.start();
    if (!ok && mounted && _voice.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_voice.error!)));
    }
    if (mounted) setState(() {});
  }

  /// The camera plugin writes every shot to the cache dir; once the bytes are
  /// in the media store (or the capture is abandoned) that copy is litter.
  void _discardShotFile() {
    final path = _shot?.path;
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  bool _shooting = false;

  Future<void> _takePhoto() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _shooting) return;
    _shooting = true;
    try {
      final shot = await camera.takePicture();
      if (!mounted) {
        // Popped mid-shutter: dispose already ran with no _shot, so this
        // cache file is ours to clean up.
        try {
          File(shot.path).deleteSync();
        } catch (_) {}
        return;
      }
      setState(() {
        _shot = shot;
        _step = 1;
      });
      _resolveZone();
    } catch (e) {
      if (mounted) setState(() => _cameraError = 'Shutter failed: $e');
    } finally {
      _shooting = false;
    }
  }

  void _noPhoto() {
    setState(() => _step = 1);
    _resolveZone();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final started = DateTime.now();
    final db = widget.db;
    final now = nowUtcIso();
    final fix = _fix;
    final obsId = newId();

    String? savedMediaId;
    String? savedVoiceId;
    try {
      // Photo first: if the image can't be written we'd rather have no
      // record than a record that claims a photograph it doesn't have.
      MediaData? media;
      final shot = _shot;
      if (shot != null && shot.path.isNotEmpty) {
        // Placed records: the photo's own GPS is the placed point too, so
        // an exported JPEG never leaks where the phone actually was.
        media = await MediaStore(db).savePhoto(
          await shot.readAsBytes(),
          propertyId: widget.property.id,
          createdBy: 'local',
          lat: widget.isPlaced ? widget.placedLat : fix?.latitude,
          lng: widget.isPlaced ? widget.placedLng : fix?.longitude,
          headingDeg: widget.isPlaced ? null : fix?.heading,
          capturedAt: now,
        );
        savedMediaId = media.id;
      }

      // Voice note: audio kept as media (spec §3.5 — never discard the
      // audio); the transcript is already in the notes text.
      MediaData? voice;
      final voicePath = _voicePath;
      if (voicePath != null && File(voicePath).existsSync()) {
        voice = await MediaStore(db).saveAudio(
          File(voicePath),
          propertyId: widget.property.id,
          createdBy: 'local',
          lat: widget.isPlaced ? widget.placedLat : fix?.latitude,
          lng: widget.isPlaced ? widget.placedLng : fix?.longitude,
          capturedAt: now,
          durationMs: _voiceMs,
          transcript: _voice.transcript.trim().isEmpty
              ? null
              : _voice.transcript.trim(),
        );
        savedVoiceId = voice.id;
        _voiceSaved = true;
        try {
          File(voicePath).deleteSync();
        } catch (_) {}
      }

      // Placed on the map: the pressed point IS the location (accuracy
      // unknown → null). Otherwise, no LIVE fix → the property centroid (or
      // the last-known hint) stands in so the record still lands on the
      // map, but gps_accuracy_m = -1 flags it. Never a silent fake.
      final placed = widget.isPlaced;
      final located = placed || (fix != null && _fixIsLive);
      final lat = placed
          ? widget.placedLat
          : fix?.latitude ?? widget.property.centroidLat;
      final lng = placed
          ? widget.placedLng
          : fix?.longitude ?? widget.property.centroidLng;
      final envService = EnvContextService(db);

      await db.transaction(() async {
        // Environmental context: created stale now, backfilled when online
        // (spec §4.11). Centroid weather is still the property's weather.
        String? envContextId;
        if (lat != null && lng != null) {
          envContextId = await envService.createStale(
            propertyId: widget.property.id,
            lat: lat,
            lng: lng,
            resolvedFor: now.substring(0, 10),
          );
        }

        await db.into(db.observations).insert(ObservationsCompanion.insert(
              id: obsId,
              propertyId: widget.property.id,
              observedAt: now,
              localTz: localTzName(),
              lat: lat ?? 0,
              lng: lng ?? 0,
              // Placed: accuracy unknown (null). Live fix: the GPS figure.
              // Otherwise -1 = "not located", never a fake.
              gpsAccuracyM: Value(placed
                  ? null
                  : located
                      ? fix!.accuracy
                      : -1),
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

        if (located && lat != null && lng != null) {
          await assignZone(db,
              observationId: obsId,
              propertyId: widget.property.id,
              lat: lat,
              lng: lng);
        }

        if (media != null) {
          await MediaStore(db).linkTo(
            media.id,
            propertyId: widget.property.id,
            entityType: 'observation',
            entityId: obsId,
            role: 'primary',
          );
        }
        if (voice != null) {
          await MediaStore(db).linkTo(
            voice.id,
            propertyId: widget.property.id,
            entityType: 'observation',
            entityId: obsId,
            role: 'attachment', // schema CHECK; media_type = 'audio' marks it
          );
        }
      });
      unawaited(envService.backfillStale());

      if (mounted) {
        Navigator.of(context)
            .pop(CaptureResult(obsId, DateTime.now().difference(started)));
      }
    } catch (e) {
      // The photo may already be in the media store with no record to own
      // it; take it back out so backups and exports don't carry an orphan.
      if (savedMediaId != null) {
        try {
          await eraseMedia(db, savedMediaId);
        } catch (_) {}
      }
      if (savedVoiceId != null) {
        try {
          await eraseMedia(db, savedVoiceId);
        } catch (_) {}
        _voiceSaved = false;
        _voicePath = null;
      }
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed — nothing written. $e')),
      );
    }
  }

  String _localNow() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)} '
        '${localTzName()}';
  }

  /// Back / ✕ on the form steps: a photo and a half-filled form are worth a
  /// question before they vanish.
  Future<void> _confirmDiscard() async {
    if (_saving) return; // the write is in flight; let it land
    final dirty = _shot != null ||
        _taxon != null ||
        _notesController.text.trim().isNotEmpty;
    if (!dirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('DISCARD THIS RECORD?'),
        content: Text(
            'The photo and anything you filled in will be dropped.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('KEEP')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('DISCARD')),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Android back: notes → form, form → confirm, shutter → leave.
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _saving) return;
        if (_step == 2) {
          setState(() => _step = 1);
        } else {
          _confirmDiscard();
        }
      },
      child: Scaffold(
        backgroundColor: Press.cameraDark,
        body: SafeArea(
          child: switch (_step) {
            0 => _buildShutter(),
            1 => _buildForm(),
            _ => _buildNotes(),
          },
        ),
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
                          style: TextStyle(
                              fontFamily: Type.serif,
                              color: Color(0xB3F4ECD8))),
                      SizedBox(height: 14),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Press.paperRaised,
                          side: BorderSide(
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
                Center(
                    child: CircularProgressIndicator(
                        color: Press.paperRaised))
              else
                CameraPreview(camera),
              // Scrim.
              DecoratedBox(
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
                  padding: EdgeInsets.all(22),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: Color(0x66F4ECD8), width: 1.5),
                    ),
                  ),
                ),
              ),
              // Corner diamonds.
              Positioned(
                  top: 30,
                  left: 30,
                  child: Diamond(size: 9, color: Press.sage)),
              Positioned(
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
                        color: Color(0x99F4ECD8), width: 1.5),
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
                    MonoLabel(
                        camera == null ? '◆ Starting camera…' : '◆ Tap to shoot',
                        size: 9.5,
                        spacing: 1.8,
                        color: Press.paperRaised),
                    MonoLabel(
                      widget.isPlaced
                          ? 'Placed on the map'
                          : fix == null
                              ? 'GPS searching — save works anyway'
                              : 'GPS ±${fix.accuracy.toStringAsFixed(0)} m',
                      size: 9.5,
                      spacing: 1.4,
                      color: Press.paperRaised,
                    ),
                  ],
                ),
              ),
              // Bottom-left coordinates: the placed point if there is one,
              // else the live fix.
              if (widget.isPlaced || fix != null)
                Positioned(
                  left: 34,
                  bottom: 34,
                  child: MonoLabel(
                    widget.isPlaced
                        ? '${widget.placedLat!.toStringAsFixed(5)}\n${widget.placedLng!.toStringAsFixed(5)}'
                        : '${fix!.latitude.toStringAsFixed(5)}\n${fix.longitude.toStringAsFixed(5)}',
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
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              SizedBox(
                width: 90,
                height: 58,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('CANCEL',
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
                  child: Text('NO PHOTO',
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
            padding: EdgeInsets.fromLTRB(13, 10, 6, 10),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: Press.ink, width: Metrics.borderStructural)),
            ),
            child: Row(
              children: [
                Diamond(size: 9, color: Press.sage),
                SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MonoLabel(
                        _shot != null ? 'Photo taken' : 'No photo',
                        size: 9.5,
                        spacing: 1.6,
                        color: Press.sage,
                      ),
                      SizedBox(height: 2),
                      MonoLabel(
                          widget.isPlaced
                              ? 'Placed on the map · ${widget.placedLat!.toStringAsFixed(5)}, ${widget.placedLng!.toStringAsFixed(5)}'
                              : fix == null
                              ? 'No GPS fix — saved without a location'
                              : !_zoneResolved
                                  ? 'GPS ±${fix.accuracy.toStringAsFixed(0)} m'
                                  : _zoneName != null
                                      ? 'GPS ±${fix.accuracy.toStringAsFixed(0)} m · $_zoneName'
                                      : 'GPS ±${fix.accuracy.toStringAsFixed(0)} m · outside any zone',
                          size: 8.5,
                          opacity: 0.65),
                    ],
                  ),
                ),
                SizedBox(
                  width: 46,
                  height: 46,
                  child: TextButton(
                    onPressed: _confirmDiscard,
                    child: Text('✕'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.all(Metrics.gutter),
              children: [
                MonoLabel(
                    _taxon == null
                        ? 'What is it? · optional — favourites first'
                        : 'What is it? · ${_taxon!.scientificName}',
                    size: 9,
                    spacing: 1.8),
                SizedBox(height: 8),
                SpeciesField(
                  db: widget.db,
                  label: 'Species — common or Latin name',
                  onSelected: (t) => setState(() {
                    _taxon = t;
                    // Naming a plant makes this a plant record unless the
                    // user already chose something more specific.
                    if (t != null && _observationType == 'general') {
                      _observationType = 'plant';
                    }
                  }),
                ),
                SizedBox(height: 16),
                MonoLabel('What kind of record', size: 9, spacing: 1.8),
                SizedBox(height: 8),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final t in _types)
                      GestureDetector(
                        onTap: () => setState(() => _observationType = t),
                        child: Container(
                          height: 56, // glove target (spec §7)
                          padding:
                              EdgeInsets.symmetric(horizontal: 18),
                          decoration: BoxDecoration(
                            color:
                                _observationType == t ? Press.ink : null,
                            border: Border.all(color: Press.borderInk, width: 1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          // Center(widthFactor) keeps the pill hugging its
                          // label; a Container with `alignment` would grow
                          // to the Wrap's full width.
                          child: Center(
                            widthFactor: 1,
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
                      ),
                  ],
                ),
                SizedBox(height: 16),
                MonoLabel('Saved with this record', size: 9, spacing: 1.8),
                SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                      color: Press.paperRaised,
                      border: Border.all(color: Press.borderInk, width: 1.5)),
                  child: Column(
                    children: [
                      FactRow('when', _localNow()),
                      FactRow(
                          'where',
                          widget.isPlaced
                              ? '${widget.placedLat!.toStringAsFixed(5)}, ${widget.placedLng!.toStringAsFixed(5)}  placed on map'
                              : fix != null
                                  ? '${fix.latitude.toStringAsFixed(5)}, ${fix.longitude.toStringAsFixed(5)}  ±${fix.accuracy.toStringAsFixed(0)} m'
                                  : 'no fix — flagged, never faked'),
                      FactRow('weather · soil',
                          'looked up when you\'re back online',
                          last: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Footer.
          Container(
            padding: EdgeInsets.all(Metrics.gutter),
            decoration: BoxDecoration(
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
                SizedBox(width: 8),
                SizedBox(
                  height: 58,
                  child: OutlinedButton(
                    onPressed: () => setState(() => _step = 2),
                    child: Text('+ NOTES'),
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
            padding: EdgeInsets.fromLTRB(6, 10, 13, 10),
            decoration: BoxDecoration(
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
                    child: Text('‹ BACK'),
                  ),
                ),
                SizedBox(width: 6),
                MonoLabel('Notes', size: 10, spacing: 1.8),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(Metrics.gutter),
              children: [
                // Voice note: one big mic target, live transcript beneath.
                ListenableBuilder(
                  listenable: _voice,
                  builder: (context, _) {
                    final rec = _voice.recording;
                    final secs = _voice.elapsed.inSeconds;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 58,
                          child: rec
                              ? FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: Press.oxblood),
                                  icon: const Icon(Icons.stop),
                                  label: Text(
                                      'STOP · ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}'),
                                  onPressed: _toggleVoice,
                                )
                              : OutlinedButton.icon(
                                  icon: const Icon(Icons.mic),
                                  label: Text(_voicePath == null
                                      ? 'RECORD A VOICE NOTE'
                                      : 'VOICE NOTE SAVED · RECORD AGAIN'),
                                  onPressed: _toggleVoice,
                                ),
                        ),
                        if (rec) ...[
                          const SizedBox(height: 8),
                          MonoLabel(
                              _voice.speechAvailable
                                  ? (_voice.transcript.isEmpty
                                      ? 'Listening…'
                                      : _voice.transcript)
                                  : 'Recording · no speech recognition on this phone',
                              size: 10,
                              opacity: 0.8),
                        ],
                        const SizedBox(height: 12),
                      ],
                    );
                  },
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 124),
                  child: TextField(
                    controller: _notesController,
                    autofocus: false,
                    textCapitalization: TextCapitalization.sentences,
                    minLines: 5,
                    maxLines: 12,
                    cursorColor: Press.oxblood,
                    style: TextStyle(
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
