import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/database.dart';
import '../id/id_models.dart';
import '../id/identification_service.dart';
import '../geo/zone_assignment.dart';
import '../app_scope.dart';
import '../repo/repos.dart';
import '../services/capture_writer.dart';
import '../services/env_context.dart';
import '../services/voice_note.dart';
import '../theme/tokens.dart';
import '../widgets/edit_record_sheet.dart' show kObservationTypes;
import '../widgets/press.dart';
import '../widgets/nativity_chip.dart';
import '../widgets/species_field.dart';
import 'identify_sheet.dart';
import '../services/diag.dart';

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
  const CaptureScreen({
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
  late final AppScope _scope = AppScope.of(context);
  ObservationsRepo get _records => _scope.observations;
  ZonesRepo get _zones => _scope.zones;
  TaxaRepo get _taxa => _scope.taxa;

  CameraController? _camera;
  String? _cameraError;
  bool _cameraPermanentlyDenied = false;

  /// Every photo for this record, in the order taken; the first is primary.
  final List<XFile> _shots = [];

  /// Reserved up front so a capture-time identification can name the record
  /// it belongs to before the row exists.
  final String _obsId = newId();
  List<IdCandidate> _pendingSuggestions = const [];
  IdCandidate? _chosenCandidate;
  int _zoneCount = -1;
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

  @override
  void initState() {
    super.initState();
    _countZones();
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
      if (!await _scope.locationHub.ensurePermission()) {
        return; // record saves without coordinates rather than blocking
      }
      if (!mounted) return;
      // A fix from before the app idled is not a fix. The OS's last-known
      // position is shown as a hint until the live stream delivers, but
      // only a LIVE fix is ever written — see _fixIsLive in _save.
      final fresh = _scope.locationHub.fresh();
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
            DateTime.now().difference(last.timestamp) < Duration(minutes: 2) &&
            mounted) {
          setState(() => _fix = last);
        }
      }
      _fixSub = _scope.locationHub.positions.listen((pos) {
        if (mounted) {
          setState(() {
            _fix = pos;
            _fixIsLive = true;
          });
        }
      });
    } catch (e, st) {
      Diag.report(e, st, where: 'CaptureScreen._initLocation');
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
        lng: fix.longitude,
      );
      Zone? zone;
      if (zoneId != null) zone = await _zones.byId(zoneId);
      if (mounted) {
        setState(() {
          _zoneName = zone?.name;
          _zoneResolved = true;
        });
      }
    } catch (e, st) {
      Diag.report(e, st, where: 'CaptureScreen._resolveZone');
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

  /// Make this spot a monitoring station too (Austin, 2026-09-04): the
  /// record saves as always, and a photo point is anchored here facing
  /// the way the phone was pointed.
  bool _asPhotoPoint = false;

  /// Flag the record for removal as it's made (D-027).
  bool _flagRemoval = false;

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
        _notesController.text = existing.isEmpty ? text : '$existing\n$text';
        _notesController.selection = TextSelection.collapsed(
          offset: _notesController.text.length,
        );
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
    for (final shot in _shots) {
      final path = shot.path;
      if (path.isEmpty) continue;
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (e, st) {
        Diag.report(e, st, where: 'CaptureScreen._discardShotFile');
      }
    }
    try {
      final f = File('');
      if (f.existsSync()) f.deleteSync();
    } catch (e, st) {
      Diag.report(e, st, where: 'CaptureScreen._discardShotFile');
    }
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
        } catch (e, st) {
          Diag.report(e, st, where: 'CaptureScreen._takePhoto');
        }
        return;
      }
      setState(() {
        _shots.add(shot);
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

  Future<void> _countZones() async {
    final n = await _zones.of(widget.property.id);
    if (mounted) setState(() => _zoneCount = n.length);
  }

  Future<void> _pickFromGallery() async {
    try {
      final picked = await ImagePicker().pickMultiImage(imageQuality: 92);
      if (picked.isEmpty || !mounted) return;
      setState(() {
        _shots.addAll(picked);
        if (_step == 0) _step = 1;
      });
      _resolveZone();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open photos: $e')));
      }
    }
  }

  /// Ask for an ID before the record exists. The suggestions are kept in
  /// memory and written the moment the row is saved (rule 7); a picked
  /// name fills the species field as "probable", never "certain".
  Future<void> _suggestSpecies() async {
    if (_shots.isEmpty) return;
    final now = nowUtcIso();
    final fix = _fix;
    final lat = widget.isPlaced
        ? widget.placedLat
        : fix?.latitude ?? widget.property.centroidLat;
    final lng = widget.isPlaced
        ? widget.placedLng
        : fix?.longitude ?? widget.property.centroidLng;
    final transient = Observation(
      id: _obsId,
      propertyId: widget.property.id,
      zoneId: null,
      observedAt: now,
      localTz: DateTime.now().timeZoneName,
      lat: lat ?? 0,
      lng: lng ?? 0,
      gpsAccuracyM: lat == null ? -1 : (widget.isPlaced ? null : fix?.accuracy),
      observationType: 'plant',
      isSuggestion: 0,
      createdBy: 'local',
      createdAt: now,
      updatedAt: now,
    );
    final service = IdentificationService(widget.db);
    try {
      await showIdentifySheet(
        context,
        db: widget.db,
        observation: transient,
        property: widget.property,
        photos: [for (final x in _shots) File(x.path)],
        persist: false,
        onCandidates: (c) => _pendingSuggestions = c,
        onChoose: (c) async {
          final taxonId = await service.ensureTaxon(c, widget.property.id);
          final taxon = await _taxa.byId(taxonId);
          if (!mounted) return;
          setState(() {
            _taxon = taxon;
            _chosenCandidate = c;
            if (_observationType == 'general') _observationType = 'plant';
          });
        },
      );
    } finally {
      service.close();
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final started = DateTime.now();
    final db = widget.db;
    final fix = _fix;
    final obsId = _obsId;

    final voicePath = _voicePath;
    final envService = EnvContextService(db);
    try {
      // The write itself lives in one place (services/capture_writer.dart)
      // so the smoke suite saves records the way this screen does. Photo
      // first, then one transaction; a failure leaves nothing behind.
      final written = await writeCapture(
        db,
        CaptureDraft(
          observationId: obsId,
          property: widget.property,
          photos: [
            for (final shot in _shots)
              if (shot.path.isNotEmpty) File(shot.path),
          ],
          voice: voicePath == null ? null : File(voicePath),
          voiceDurationMs: _voiceMs,
          voiceTranscript: _voice.transcript,
          placedLat: widget.placedLat,
          placedLng: widget.placedLng,
          fix: fix == null
              ? null
              : CaptureFix(
                  lat: fix.latitude,
                  lng: fix.longitude,
                  accuracyM: fix.accuracy,
                  altitudeM: fix.altitude,
                  headingDeg: fix.heading,
                ),
          fixIsLive: _fixIsLive,
          observationType: _observationType,
          taxonId: _taxon?.id,
          taxonChosenFromSuggestion: _chosenCandidate != null,
          flagRemoval: _flagRemoval,
          notes: _notesController.text,
          asPhotoPoint: _asPhotoPoint,
          photoPointSubject: _taxon?.commonName ?? _taxon?.scientificName,
        ),
        envService: envService,
      );
      if (written.voiceMediaId != null) {
        // The recording is in the media store; nothing left to discard.
        _voiceSaved = true;
        _voicePath = null;
      }
      unawaited(envService.backfillStale());

      if (mounted) {
        // Capture-time suggestions now have a row to belong to (rule 7).
        if (_pendingSuggestions.isNotEmpty) {
          final svc = IdentificationService(db);
          try {
            final row = await _records.single(obsId);
            final rid = await svc.recordSuggestions(_pendingSuggestions, row);
            final chosen = _chosenCandidate;
            if (chosen != null) {
              await svc.accept(
                candidate: chosen,
                observationId: obsId,
                propertyId: widget.property.id,
                runId: rid,
              );
            }
          } catch (e, st) {
            Diag.report(e, st, where: 'CaptureScreen._save');
            // The record is saved; a missing suggestion row is not worth a scare.
          } finally {
            svc.close();
          }
        }
        // Identification can run long; if the capture screen has already
        // been left by then, there is nothing to pop.
        if (!mounted) return;
        Navigator.of(context)
            .pop(CaptureResult(obsId, DateTime.now().difference(started)));
      }
    } catch (e) {
      // writeCapture has already taken back any media it wrote, and the
      // voice note's temp file is still where it was, so SAVE can be tried
      // again with everything still in hand.
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
    final dirty =
        _shots.isNotEmpty ||
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
        content: Text('The photo and anything you filled in will be dropped.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('KEEP'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('DISCARD'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Android back: notes → form, form → confirm, shutter → confirm too
      // when a photo/species/notes exist (a re-shot photo lives at step 0;
      // it must not vanish silently — Austin's audit, 2026-09-03).
      canPop: false,
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
                      Text(
                        _cameraError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: Type.serif,
                          color: Color(0xB3F4ECD8),
                        ),
                      ),
                      SizedBox(height: 14),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Press.paperRaised,
                          side: BorderSide(
                            color: Press.paperRaised,
                            width: 1.5,
                          ),
                        ),
                        onPressed: () async {
                          if (_cameraPermanentlyDenied) {
                            await openAppSettings();
                          } else {
                            setState(() => _cameraError = null);
                            await _initCamera();
                          }
                        },
                        child: Text(
                          _cameraPermanentlyDenied
                              ? 'OPEN SETTINGS'
                              : 'GRANT CAMERA ACCESS',
                        ),
                      ),
                    ],
                  ),
                )
              else if (camera == null)
                Center(
                  child: CircularProgressIndicator(color: Press.paperRaised),
                )
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
                      border: Border.all(color: Color(0x66F4ECD8), width: 1.5),
                    ),
                  ),
                ),
              ),
              // Corner diamonds.
              Positioned(
                top: 30,
                left: 30,
                child: Diamond(size: 9, color: Press.sage),
              ),
              Positioned(
                top: 30,
                right: 30,
                child: Diamond(size: 9, color: Press.sage),
              ),
              // Focus square.
              Center(
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    border: Border.all(color: Color(0x99F4ECD8), width: 1.5),
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
                      color: Press.paperRaised,
                    ),
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
                width: 112,
                height: 58,
                child: TextButton(
                  onPressed: _confirmDiscard,
                  child: Text(
                    'CANCEL',
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: TextStyle(color: Color(0x99F4ECD8)),
                  ),
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
                    border: Border.all(color: Press.paperRaised, width: 4),
                  ),
                ),
              ),
              SizedBox(
                width: 90,
                height: 58,
                child: TextButton(
                  onPressed: _noPhoto,
                  child: Text(
                    'NO PHOTO',
                    style: TextStyle(color: Color(0x99F4ECD8)),
                  ),
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
                  color: Press.ink,
                  width: Metrics.borderStructural,
                ),
              ),
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
                        _shots.isEmpty
                            ? 'No photo'
                            : _shots.length == 1
                            ? 'Photo taken'
                            : '${_shots.length} photos',
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
                            : 'GPS ±${fix.accuracy.toStringAsFixed(0)} m · ${noZoneLabel(_zoneCount)}',
                        size: 8.5,
                        opacity: 0.65,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 56,
                  height: 56,
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
                // More photos, and a machine's opinion before you name it.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: _asPhotoPoint ? Press.ink : null,
                          foregroundColor: _asPhotoPoint
                              ? Press.paper
                              : Press.ink,
                        ),
                        icon: Icon(
                          _asPhotoPoint
                              ? Icons.center_focus_strong
                              : Icons.center_focus_weak,
                          size: 18,
                        ),
                        label: Text(
                          _asPhotoPoint ? 'PHOTO POINT ✓' : 'PHOTO POINT',
                        ),
                        onPressed: () =>
                            setState(() => _asPhotoPoint = !_asPhotoPoint),
                      ),
                    ),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: _flagRemoval ? Press.oxblood : null,
                          foregroundColor: _flagRemoval
                              ? Press.paper
                              : Press.oxblood,
                          side: BorderSide(color: Press.oxblood, width: 1.5),
                        ),
                        icon: Icon(Icons.content_cut, size: 18),
                        label: Text(
                          _flagRemoval ? 'REMOVAL ✓' : 'FLAG FOR REMOVAL',
                        ),
                        onPressed: () =>
                            setState(() => _flagRemoval = !_flagRemoval),
                      ),
                    ),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        icon: Icon(Icons.photo_camera_outlined, size: 18),
                        label: Text(
                          _shots.isEmpty ? 'TAKE A PHOTO' : 'ANOTHER PHOTO',
                        ),
                        onPressed: () => setState(() => _step = 0),
                      ),
                    ),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        icon: Icon(Icons.photo_library_outlined, size: 18),
                        label: Text('FROM GALLERY'),
                        onPressed: _pickFromGallery,
                      ),
                    ),
                    if (_shots.isNotEmpty)
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          icon: Icon(Icons.eco_outlined, size: 18),
                          label: Text('SUGGEST A SPECIES'),
                          onPressed: _suggestSpecies,
                        ),
                      ),
                  ],
                ),
                if (_shots.isNotEmpty) ...[
                  SizedBox(height: 12),
                  // The photos in hand (Austin, 2026-09-07: "you don't see
                  // the image, much less the other 3-4 you took"). Every
                  // one goes on the record; the identify sheet is where
                  // you pick which go to Pl@ntNet.
                  SizedBox(
                    height: 84,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _shots.length,
                      separatorBuilder: (_, _) => SizedBox(width: 8),
                      itemBuilder: (context, i) => Stack(
                        children: [
                          Container(
                            width: 84,
                            height: 84,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Press.borderInk,
                                width: 1.5,
                              ),
                              image: DecorationImage(
                                image: FileImage(File(_shots[i].path)),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            right: 0,
                            child: GestureDetector(
                              onTap: () => setState(() => _shots.removeAt(i)),
                              child: Container(
                                width: 28,
                                height: 28,
                                color: Press.ink,
                                child: Icon(
                                  Icons.close,
                                  size: 16,
                                  color: Press.paper,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: MonoLabel(
                        _taxon == null
                            ? 'What is it? · optional — favourites first'
                            : 'What is it? · ${_taxon!.scientificName}',
                        size: 9,
                        spacing: 1.8,
                      ),
                    ),
                    if (_taxon?.nativity != null)
                      NativityChip(_taxon!.nativity),
                  ],
                ),
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
                    for (final t in kObservationTypes)
                      GestureDetector(
                        onTap: () => setState(() => _observationType = t),
                        child: Container(
                          height: 56, // glove target (spec §7)
                          padding: EdgeInsets.symmetric(horizontal: 18),
                          decoration: BoxDecoration(
                            color: _observationType == t ? Press.ink : null,
                            border: Border.all(
                              color: Press.borderInk,
                              width: 1,
                            ),
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
                    border: Border.all(color: Press.borderInk, width: 1.5),
                  ),
                  child: Column(
                    children: [
                      FactRow('when', _localNow()),
                      FactRow(
                        'where',
                        widget.isPlaced
                            ? '${widget.placedLat!.toStringAsFixed(5)}, ${widget.placedLng!.toStringAsFixed(5)}  placed on map'
                            : fix != null
                            ? '${fix.latitude.toStringAsFixed(5)}, ${fix.longitude.toStringAsFixed(5)}  ±${fix.accuracy.toStringAsFixed(0)} m'
                            : 'no fix — flagged, never faked',
                      ),
                      FactRow(
                        'weather · soil',
                        'looked up when you\'re back online',
                        last: true,
                      ),
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
              border: Border(top: BorderSide(color: Press.divider, width: 1)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 58,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'WRITING…' : 'SAVE OBSERVATION'),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                SizedBox(
                  height: 58,
                  width: 58,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                    // Dictating beats typing with gloves on: one tap from
                    // the photo to a running recording (spec §7.2).
                    onPressed: () {
                      setState(() => _step = 2);
                      _toggleVoice();
                    },
                    child: Icon(Icons.mic_none, size: 22),
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
                  color: Press.ink,
                  width: Metrics.borderStructural,
                ),
              ),
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
                                    backgroundColor: Press.oxblood,
                                  ),
                                  icon: const Icon(Icons.stop),
                                  label: Text(
                                    'STOP · ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
                                  ),
                                  onPressed: _toggleVoice,
                                )
                              : OutlinedButton.icon(
                                  icon: const Icon(Icons.mic),
                                  label: Text(
                                    _voicePath == null
                                        ? 'RECORD A VOICE NOTE'
                                        : 'VOICE NOTE SAVED · RECORD AGAIN',
                                  ),
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
                            opacity: 0.8,
                          ),
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
                      height: 1.6,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'What did you see?',
                    ),
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
