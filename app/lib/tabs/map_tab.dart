import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../db/database.dart';
import '../geo/site_presence.dart';
import '../main.dart' show locationHub, trackRecorder;
import '../map/area_downloader.dart';
import '../map/map_screen.dart';
import '../services/app_prefs.dart';
import '../services/network_policy.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import '../widgets/feature_sheet.dart';
import '../widgets/records_here_sheet.dart';

/// Map home (design README §3.1): full-bleed map with card chrome — property
/// card (tap = property switcher), track toggle, GPS badge.
class MapTab extends StatefulWidget {
  MapTab({
    super.key,
    required this.db,
    required this.property,
    required this.onPropertyCardTap,
    required this.prefs,
    this.onDropRecord,
    this.onRecordTap,
    this.active = true,
  });

  final FieldNotesDb db;
  final Property property;
  final AppPrefs prefs;

  /// Is this tab the one showing? Off-screen, the live GPS dot pauses.
  final bool active;

  /// Tap on a record pin → open it.
  final ValueChanged<String>? onRecordTap;
  final VoidCallback onPropertyCardTap;

  /// Long-press on the map → capture a record placed at that point.
  final ValueChanged<LatLng>? onDropRecord;

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  int _zoneCount = 0;
  MapLibreMapController? _controller;
  bool _captureMode = false;
  final _downloader = AreaDownloader();
  int _mapEpoch = 0; // bump to rebuild the map after a capture

  @override
  void dispose() {
    _downloader.dispose();
    super.dispose();
  }

  /// Offline basemap bounds `[minLon, minLat, maxLon, maxLat]`, or null if
  /// unknown.
  List<double>? _coverage;

  bool _covered(Position fix) {
    final b = _coverage;
    if (b == null) return true; // unknown → don't nag
    return fix.longitude >= b[0] &&
        fix.longitude <= b[2] &&
        fix.latitude >= b[1] &&
        fix.latitude <= b[3];
  }

  // Layer toggles (spec §7.1): record types, zones, tracks. Kept on the tab
  // so they survive the map being re-keyed after a capture.
  static const _types = [
    'general',
    'plant',
    'wildlife',
    'problem',
    'water',
    'soil',
    'phenology',
    'sign',
    'weather',
    'maintenance',
  ];
  final Set<String> _hiddenTypes = {};

  /// What a plant is, as the library records it. Filtering by this is the
  /// point of the map for a planting: where are the trees, where's the grass.
  static const _growthForms = [
    'tree',
    'shrub',
    'graminoid',
    'forb',
    'vine',
    'succulent',
    'fern',
    'moss',
  ];
  static const _growthLabels = {
    'tree': 'trees',
    'shrub': 'shrubs',
    'graminoid': 'grasses',
    'forb': 'forbs',
    'vine': 'vines',
    'succulent': 'succulents',
    'fern': 'ferns',
    'moss': 'mosses',
  };
  final Set<String> _hiddenGrowth = {};

  /// Records to draw: how many are on the map right now.
  int _recordCount = 0;

  /// Where the phone is relative to this place.
  SitePresence _presence = SitePresence.unknown;
  bool _showZones = true;
  bool _showTracks = true;
  bool _showFeatures = true;

  /// Satellite imagery draws over the offline vector map. The standard view
  /// (on by default, remembered): imagery is what the ground actually looks
  /// like, and it covers everywhere there's signal — including the gaps an
  /// offline extract doesn't reach, which used to read as "the map didn't
  /// load". Offline with no signal, the raster tiles simply don't draw and
  /// the vector map underneath carries on.
  late bool _showSatellite = widget.prefs.mapSatellite;
  bool get _layersTouched =>
      _hiddenTypes.isNotEmpty ||
      _hiddenGrowth.isNotEmpty ||
      !_showZones ||
      !_showTracks ||
      !_showFeatures ||
      !_showSatellite;

  Future<void> _applyLayers() async {
    final c = _controller;
    if (c == null) return;
    for (final id in ['zones-fill', 'zones-line']) {
      try {
        await c.setLayerVisibility(id, _showZones);
      } catch (_) {}
    }
    try {
      await c.setLayerVisibility('tracks-line', _showTracks);
      for (final id in ['features-fill', 'features-line', 'features-pt']) {
        await c.setLayerVisibility(id, _showFeatures);
      }
    } catch (_) {}
    try {
      await c.setLayerVisibility('satellite', _showSatellite);
    } catch (_) {}
  }

  Future<void> _showLayersSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(13, 14, 13, 8),
            children: [
              MonoLabel(
                _recordCount == 0
                    ? 'Show on the map'
                    : 'Show on the map · $_recordCount record${_recordCount == 1 ? '' : 's'}',
                size: 9,
                spacing: 2,
              ),
              SizedBox(height: 8),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final t in _types)
                    _pill(t, !_hiddenTypes.contains(t), () {
                      setSheet(() {
                        if (!_hiddenTypes.remove(t)) _hiddenTypes.add(t);
                      });
                      setState(() {});
                      _applyLayers();
                    }),
                ],
              ),
              SizedBox(height: 14),
              MonoLabel('Plants by kind', size: 9, spacing: 2),
              const SizedBox(height: 8),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final g in _growthForms)
                    _pill(_growthLabels[g]!, !_hiddenGrowth.contains(g), () {
                      setSheet(() {
                        if (!_hiddenGrowth.remove(g)) _hiddenGrowth.add(g);
                      });
                      setState(() {});
                      _applyLayers();
                    }),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  _pill('zones', _showZones, () {
                    setSheet(() => _showZones = !_showZones);
                    setState(() {});
                    _applyLayers();
                  }),
                  _pill('tracks', _showTracks, () {
                    setSheet(() => _showTracks = !_showTracks);
                    setState(() {});
                    _applyLayers();
                  }),
                  _pill('features', _showFeatures, () {
                    setSheet(() => _showFeatures = !_showFeatures);
                    setState(() {});
                    _applyLayers();
                  }),
                  _pill('satellite', _showSatellite, () {
                    setSheet(() => _showSatellite = !_showSatellite);
                    widget.prefs.mapSatellite = _showSatellite;
                    setState(() {});
                    _applyLayers();
                  }),
                  if (_layersTouched)
                    _pill('reset', false, () {
                      setSheet(() {
                        _hiddenTypes.clear();
                        _hiddenGrowth.clear();
                        _showZones = true;
                        _showTracks = true;
                        _showFeatures = true;
                        _showSatellite = true;
                        widget.prefs.mapSatellite = true;
                      });
                      setState(() {});
                      _applyLayers();
                    }),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: on ? Press.ink : null,
          border: Border.all(color: Press.borderInk, width: 1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: Type.mono,
              fontSize: 9.5,
              letterSpacing: 1.4,
              color: on ? Press.paper : Press.ink,
            ),
          ),
        ),
      ),
    );
  }

  /// Show the whole place: the boundary if there is one, else its centre.
  /// This is what the badge does when you're not standing on the property.
  Future<void> _flyToProperty() async {
    final controller = _controller;
    if (controller == null) return;
    final bounds = propertyBounds(widget.property);
    try {
      if (bounds != null) {
        await controller.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(bounds[1], bounds[0]),
              northeast: LatLng(bounds[3], bounds[2]),
            ),
            left: 40,
            right: 40,
            top: 120,
            bottom: 140,
          ),
        );
        return;
      }
      final centre = propertyCentre(widget.property);
      if (centre != null) {
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(centre[1], centre[0]), 14),
        );
      }
    } catch (_) {}
  }

  /// Locate-me: fly the camera to the current fix, close enough to see the
  /// plant you're standing next to. Blank paper there gets an explanation.
  Future<void> _flyTo(Position fix) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(fix.latitude, fix.longitude), 17.5),
      );
    } catch (_) {}
    if (!_covered(fix) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No offline map for this spot yet — ⌗ Capture area downloads it '
            'while you have signal.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _captureArea() async {
    final controller = _controller;
    if (controller == null || _downloader.downloading) return;
    final region = await controller.getVisibleRegion();
    final sw = region.southwest;
    final ne = region.northeast;
    final (count, maxZ) = AreaDownloader.estimate(
      sw.longitude,
      sw.latitude,
      ne.longitude,
      ne.latitude,
    );
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('CAPTURE THIS AREA?'),
        content: Text(
          '$count tiles to z$maxZ — roughly '
          '${(count * 40 / 1024).toStringAsFixed(0)} MB. Downloads once from '
          'OpenStreetMap (Protomaps build) and lives on this phone. Areas '
          'accumulate; capture as many as you walk.',
          style: TextStyle(fontFamily: Type.serif, fontSize: 15, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('CAPTURE'),
          ),
        ],
      ),
    );
    if (go != true) return;
    // D-016: bulk download waits for Wi-Fi unless the user allows cellular.
    final verdict = await NetworkPolicy().bulkVerdict(widget.prefs);
    if (!mounted) return;
    if (verdict == BulkVerdict.offline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('NO SIGNAL — CAPTURE THIS AREA WHEN YOU HAVE ONE'),
        ),
      );
      return;
    }
    if (verdict == BulkVerdict.cellularBlocked) {
      final allow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('YOU\'RE ON CELLULAR'),
          content: Text(
            'This download uses mobile data. Allow it this once, or turn on '
            'cellular downloads in Settings → Network to stop asking.',
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 15,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('WAIT FOR WI-FI'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('USE DATA THIS ONCE'),
            ),
          ],
        ),
      );
      if (allow != true || !mounted) return;
    }
    setState(() => _captureMode = false);
    await _downloader.download(
      sw.longitude,
      sw.latitude,
      ne.longitude,
      ne.latitude,
    );
    if (!mounted) return;
    if (_downloader.error == null) {
      // Reload the map onto the captured store.
      setState(() => _mapEpoch++);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          (_downloader.error != null
                  ? 'CAPTURE FAILED: ${_downloader.error}'
                  : _downloader.status ?? 'CAPTURED')
              .toUpperCase(),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  @override
  void didUpdateWidget(MapTab old) {
    super.didUpdateWidget(old);
    if (old.property.id != widget.property.id) _loadCounts();
  }

  Future<void> _loadCounts() async {
    final zones =
        await (widget.db.select(widget.db.zones)
              ..where((z) => z.propertyId.equals(widget.property.id))
              ..where((z) => z.deletedAt.isNull()))
            .get();
    if (mounted) setState(() => _zoneCount = zones.length);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          // KeyedSubtree so switching properties rebuilds the map + overlays.
          child: KeyedSubtree(
            key: ValueKey('${widget.property.id}-$_mapEpoch'),
            child: MapScreen(
              db: widget.db,
              property: widget.property,
              embedded: true,
              onController: (c) => _controller = c,
              // Fires when the style and every overlay layer exist — the
              // only safe moment to re-apply toggles after a re-key.
              onLayersReady: _applyLayers,
              onCoverage: (b) => _coverage = b,
              onPresence: (p) {
                if (mounted && p.onSite != _presence.onSite) {
                  setState(() => _presence = p);
                } else {
                  _presence = p;
                }
              },
              hiddenTypes: _hiddenTypes,
              hiddenGrowthForms: _hiddenGrowth,
              onRecordCount: (n) {
                if (mounted && n != _recordCount) {
                  setState(() => _recordCount = n);
                }
              },
              onLongPress: _captureMode ? null : widget.onDropRecord,
              visible: widget.active,
              onRecordTap: widget.onRecordTap,
              onFeatureTap: (fid) => showFeatureSheet(
                context,
                db: widget.db,
                property: widget.property,
                featureId: fid,
              ),
              onClusterTap: (ids) => showRecordsHereSheet(
                context,
                db: widget.db,
                ids: ids,
                onOpen: widget.onRecordTap,
              ),
            ),
          ),
        ),
        // Capture-area frame: the visible region is what gets captured.
        if (_captureMode)
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 120, 22, 150),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Press.oxblood, width: 2),
                  ),
                ),
              ),
            ),
          ),
        if (_captureMode)
          Positioned(
            left: 22,
            right: 22,
            bottom: 90,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: _captureArea,
                    child: const Text('CAPTURE THIS AREA'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: () => setState(() => _captureMode = false),
                    child: const Text('CANCEL'),
                  ),
                ),
              ],
            ),
          ),
        ListenableBuilder(
          listenable: _downloader,
          builder: (context, _) => _downloader.downloading
              ? Positioned(
                  left: 22,
                  right: 22,
                  bottom: 90,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Press.ink,
                      border: Border.all(color: Press.paperEdge, width: 1.5),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LinearProgressIndicator(
                          value: _downloader.progress,
                          color: Press.oxblood,
                          backgroundColor: const Color(0x33ECE3CE),
                        ),
                        const SizedBox(height: 7),
                        MonoLabel(
                          _downloader.status ?? 'Capturing…',
                          size: 9.5,
                          color: Press.paper,
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Property card — hard offset shadow; the switcher.
                    // Flexible: a long place name wraps inside the card
                    // instead of pushing the controls off the screen.
                    Flexible(
                      child: GestureDetector(
                        onTap: widget.onPropertyCardTap,
                        child: InkCard(
                          color: Press.paper,
                          shadow: true,
                          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.property.name.toUpperCase(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: Type.slab,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 15,
                                  color: Press.ink,
                                ),
                              ),
                              const SizedBox(height: 3),
                              MonoLabel(
                                [
                                  if (_zoneCount > 0) '$_zoneCount zones',
                                  if (widget.property.acreage != null)
                                    '${widget.property.acreage!.toStringAsFixed(2)} ac',
                                  widget.property.landTenure.replaceAll(
                                    '_',
                                    ' ',
                                  ),
                                ].join(' · '),
                                size: 9,
                                spacing: 1.4,
                                opacity: 0.8,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _TrackToggle(propertyId: widget.property.id),
                        const SizedBox(height: 7),
                        GestureDetector(
                          onTap: () =>
                              setState(() => _captureMode = !_captureMode),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: _captureMode ? Press.oxblood : Press.paper,
                              border: Border.all(
                                color: Press.borderInk,
                                width: 1.5,
                              ),
                            ),
                            child: MonoLabel(
                              '⌗ Capture area',
                              size: 9.5,
                              spacing: 1.4,
                              color: _captureMode ? Press.paper : Press.ink,
                            ),
                          ),
                        ),
                        const SizedBox(height: 7),
                        // Layers: record types, zones, tracks.
                        GestureDetector(
                          onTap: _showLayersSheet,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: _layersTouched ? Press.ink : Press.paper,
                              border: Border.all(
                                color: Press.borderInk,
                                width: 1.5,
                              ),
                            ),
                            child: MonoLabel(
                              _layersTouched
                                  ? '◈ Layers · filtered'
                                  : '◈ Layers',
                              size: 9.5,
                              spacing: 1.4,
                              color: _layersTouched ? Press.paper : Press.ink,
                            ),
                          ),
                        ),
                        const SizedBox(height: 7),
                        // GPS: status readout AND the locate-me control.
                        // Tap → fly to the current fix.
                        ListenableBuilder(
                          listenable: locationHub,
                          builder: (context, _) {
                            // While a track runs the stream is distance-
                            // filtered, so standing still is silence, not
                            // a lost fix — trust the last one then.
                            final fix =
                                locationHub.fresh() ??
                                (locationHub.foreground
                                    ? locationHub.last
                                    : null);
                            final presence = fix == null
                                ? SitePresence.unknown
                                : presenceFor(
                                    widget.property,
                                    fix.latitude,
                                    fix.longitude,
                                  );
                            // Off the property, the useful move is to show
                            // the property — not to drag the map to town.
                            final offSite =
                                fix != null &&
                                !presence.onSite &&
                                presence.distanceM != null;
                            final label = fix == null
                                ? 'GPS · searching'
                                : offSite
                                ? '${presence.awayLabel} · show the place'
                                : 'GPS ±${fix.accuracy.toStringAsFixed(0)} m · find me';
                            return GestureDetector(
                              onTap: fix == null
                                  ? null
                                  : offSite
                                  ? _flyToProperty
                                  : () => _flyTo(fix),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Press.paper,
                                  border: Border.all(
                                    color: fix == null
                                        ? Press.sage
                                        : offSite
                                        ? Press.ochre
                                        : Press.ink,
                                    width: 1.5,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Diamond(
                                      size: 9,
                                      color: fix == null
                                          ? Press.sage
                                          : offSite
                                          ? Press.ochre
                                          : Press.river,
                                      filled: fix != null,
                                      blink: fix == null,
                                    ),
                                    const SizedBox(width: 6),
                                    MonoLabel(
                                      label,
                                      size: 9.5,
                                      spacing: 1.4,
                                      color: fix == null
                                          ? Press.sage
                                          : offSite
                                          ? Press.ochre
                                          : Press.ink,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TrackToggle extends StatelessWidget {
  const _TrackToggle({required this.propertyId});
  final String propertyId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: trackRecorder,
      builder: (context, _) {
        final on =
            trackRecorder.recording &&
            trackRecorder.activePropertyId == propertyId;
        return GestureDetector(
          onTap: () async {
            if (on) {
              await trackRecorder.stop();
            } else if (!trackRecorder.recording) {
              await trackRecorder.start(propertyId);
              // A recorder that can't hear the GPS must say so, not sit
              // at 0.0 km looking busy.
              final err = trackRecorder.lastError;
              if (err != null && context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(err)));
              }
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: on ? Press.oxblood : Press.paper,
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: MonoLabel(
              on
                  ? trackRecorder.lastError != null
                        ? '◼ Track · GPS lost'
                        : '◼ Track ${(trackRecorder.distanceSoFarM / 1000).toStringAsFixed(1)} km'
                  : '▶ Log track',
              size: 9.5,
              spacing: 1.4,
              color: on ? Press.paper : Press.ink,
            ),
          ),
        );
      },
    );
  }
}
