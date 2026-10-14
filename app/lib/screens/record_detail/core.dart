part of '../record_detail_screen.dart';

/// The record screen's state: what was loaded for this record, and the
/// one audio player it may need.
mixin _RecordDetailCore on State<RecordDetailScreen> {
  late final AppScope _scope = AppScope.of(context);
  ObservationsRepo get _records => _scope.observations;
  MediaRepo get _media => _scope.media;
  ZonesRepo get _zones => _scope.zones;
  TaxaRepo get _taxa => _scope.taxa;
  PropertiesRepo get _properties => _scope.properties;
  PhotoPointsRepo get _photoPoints => _scope.photoPoints;

  Observation? _obs;
  bool _gone = false;
  TaxaData? _taxon;
  Zone? _zone;
  EnvContext? _env;
  ReviewItem? _review;
  List<MediaData> _photos = [];

  /// The station this record's photo anchors, if it became one.
  PhotoPoint? _photoPoint;

  /// The monitoring run this record was made as (D-033), if it was one.
  ProtocolRun? _run;
  Protocol? _runProtocol;
  ProtocolSite? _runSite;
  List<Indicator> _runIndicators = const [];
  List<MediaData> _audio = [];
  List<(Observation, double)> _nearby = [];
  Property? _property;
  int _photoIndex = 0;
  int _zoneCount = -1;
  // Lazy: the audio engine exists only once a voice note actually
  // plays — a record with no recording must not spin one up (and the
  // desk test host has no audio plugin at all). Audit 2026-09-05.
  AudioPlayer? _playerInstance;
  AudioPlayer get _player => _playerInstance ??= AudioPlayer();
  String? _playingId;

  Future<void> _load() async {
    final db = widget.db;
    final obs = await _records.byId(widget.obsId);
    if (obs == null) {
      if (mounted) setState(() => _gone = true);
      return;
    }
    final property = await _properties.byId(obs.propertyId);
    TaxaData? taxon;
    if (obs.taxonId != null) taxon = await _taxa.byId(obs.taxonId!);
    Zone? zone;
    if (obs.zoneId != null) zone = await _zones.byId(obs.zoneId!);
    EnvContext? env;
    if (obs.envContextId != null) {
      env = await _records.envContext(obs.envContextId!);
    }
    final photos = <MediaData>[];
    final audio = <MediaData>[];
    for (final m in await _media.linkedTo(entityId: obs.id)) {
      if (m.localPath == null || !File(m.localPath!).existsSync()) continue;
      if (m.mediaType == 'audio') {
        audio.add(m);
      } else {
        photos.add(m);
      }
    }
    // Related (spec §7.4): other records within 50 m — the same plant
    // photographed again, the same spring checked again.
    final nearby = await _records.nearby(obs);
    final review = await ReviewService(widget.db)
        .forEntity('observation', widget.obsId);
    final photoPoint = photos.isEmpty
        ? null
        : await _photoPoints.anchoredBy([for (final m in photos) m.id]);
    final zoneRows = await _zones.of(obs.propertyId);
    ProtocolRun? run;
    Protocol? runProtocol;
    ProtocolSite? runSite;
    var runIndicators = const <Indicator>[];
    if (obs.observationType == 'survey') {
      final svc = ProtocolService(db);
      run = await svc.runForObservation(obs.id);
      if (run != null) {
        runProtocol = await svc.protocolById(run.protocolId);
        runSite = await svc.siteById(run.siteId);
        if (runProtocol != null && runSite != null) {
          runIndicators = await svc.indicatorsFor(runProtocol, runSite, run);
        }
      }
    }
    if (mounted) {
      setState(() {
        _run = run;
        _runProtocol = runProtocol;
        _runSite = runSite;
        _runIndicators = runIndicators;
        _review = review;
        _obs = obs;
        _taxon = taxon;
        _zone = zone;
        _env = env;
        _photos = photos;
        _photoPoint = photoPoint;
        _audio = audio;
        _nearby = nearby.take(6).toList();
        _property = property;
        _zoneCount = zoneRows.length;
      });
    }
  }

  String _fmtDate(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _fmtMs(int? ms) {
    if (ms == null) return 'play';
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _play(MediaData a) async {
    if (_playingId == a.id) {
      await _player.stop();
      if (mounted) setState(() => _playingId = null);
      return;
    }
    try {
      await _player.stop();
      _player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playingId = null);
      });
      await _player.play(DeviceFileSource(a.localPath!));
      if (mounted) setState(() => _playingId = a.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not play: $e')));
      }
    }
  }
}
