import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../app_scope.dart';
import '../db/database.dart';
import '../geo/site_presence.dart';
import '../map/area_downloader.dart';
import '../map/map_screen.dart';
import '../repo/repos.dart';
import '../services/app_prefs.dart';
import '../services/field_network.dart';
import '../services/network_policy.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import '../screens/photo_points/photo_point_history_screen.dart';
import '../screens/polygon_editor_screen.dart';
import '../widgets/feature_sheet.dart';
import '../widgets/records_here_sheet.dart';
import '../services/diag.dart';

part 'map_tab/core.dart';
part 'map_tab/filter.dart';
part 'map_tab/shapes.dart';
part 'map_tab/layers.dart';
part 'map_tab/camera.dart';
part 'map_tab/chrome.dart';

/// Map home (design README §3.1): full-bleed map with card chrome — property
/// card (tap = property switcher), track toggle, GPS badge.
class MapTab extends StatefulWidget {
  const MapTab({
    super.key,
    required this.db,
    required this.property,
    required this.onPropertyCardTap,
    required this.prefs,
    this.onDropRecord,
    this.onRecordTap,
    this.active = true,
    this.focus,
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

  /// Another tab asks the map to go somewhere (ledger LOCATE): set a
  /// LatLng here; the map flies to it and clears it.
  final ValueNotifier<LatLng?>? focus;

  @override
  State<MapTab> createState() => _MapTabState();
}

/// Split along its concerns (D-038 item 7): state in `map_tab/core.dart`,
/// then the filter, the shape editor, the layers sheet, the camera, and
/// the chrome over the map. One object, seven files.
class _MapTabState extends State<MapTab>
    with
        _MapTabCore,
        _MapTabFilter,
        _MapTabShapes,
        _MapTabLayers,
        _MapTabCamera,
        _MapTabChrome {
  @override
  void dispose() {
    widget.focus?.removeListener(_onFocusRequest);
    _scope.mapJump.removeListener(_onMapJump);
    _scope.recordFilter.removeListener(_onFilterChanged);
    _downloader.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scope.recordFilter.addListener(_onFilterChanged);
    widget.focus?.addListener(_onFocusRequest);
    _scope.mapJump.addListener(_onMapJump);
    _loadCounts();
    // One-time hint: long-press-to-place has zero discoverability
    // otherwise (design audit P2).
    if (!(widget.prefs.get<bool>('hint_hold_map') ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(seconds: 2), () {
          if (!mounted) return;
          widget.prefs.set('hint_hold_map', true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              duration: Duration(seconds: 5),
              content: Text('Hold the map to place a record at that spot.'),
            ),
          );
        });
      });
    }
  }

  @override
  void didUpdateWidget(MapTab old) {
    super.didUpdateWidget(old);
    if (old.property.id != widget.property.id) _loadCounts();
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
              onController: (c) {
                _controller = c;
                _consumeFocus();
                _onMapJump();
              },
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
              onRecordCount: (n) {
                if (mounted && n != _recordCount) {
                  setState(() => _recordCount = n);
                }
              },
              onLongPress: _captureMode ? null : widget.onDropRecord,
              visible: widget.active,
              onRecordTap: widget.onRecordTap,
              onPhotoPointTap: (ppid) async {
                final p = await _photoPoints.byId(ppid);
                if (p == null || !context.mounted) return;
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        PhotoPointHistoryScreen(db: widget.db, point: p),
                  ),
                );
              },
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
        ..._chromeChildren(),
      ],
    );
  }
}
