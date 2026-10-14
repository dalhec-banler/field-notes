part of '../capture_screen.dart';

/// The capture screen's state and the actions on it: camera, GPS fix,
/// zone lookup, voice note, shots. Every step draws from here.
mixin _CaptureCore on State<CaptureScreen> {
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
}
