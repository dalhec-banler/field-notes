part of '../desk_map_view.dart';

String _cap(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// The marks: clustering, species groups, flying to things, and what a
/// click lands on.
mixin _DeskMapMarks on _DeskMapTiles {
  bool _isLit(MapRecord r) =>
      _highlightKey == null || (r.label ?? '__type:${r.type}') == _highlightKey;

  (List<List<MapRecord>> lit, List<List<MapRecord>> dimmed) _clustersFor(
    MapLayerSet s,
  ) {
    final key = (_zoom, s, _highlightKey, _selectedId);
    if (_clusterKey == key) return _clusters;
    _clusterKey = key;
    final lit = <MapRecord>[];
    final dimmed = <MapRecord>[];
    MapRecord? selected;
    for (final r in s.records) {
      if (r.id != null && r.id == _selectedId) {
        selected = r;
        continue;
      }
      (_isLit(r) ? lit : dimmed).add(r);
    }
    final litCells = clusterBy(lit, recordCoords, _zoom);
    final dimCells = clusterBy(dimmed, recordCoords, _zoom);
    if (selected != null) {
      (_isLit(selected) ? litCells : dimCells).add([selected]);
    }
    return _clusters = (litCells, dimCells);
  }

  /// The phone's Zillow move: click a badge, land where it splits. A
  /// cell that never splits — repeat visits to one marked tree, or points
  /// closer than this imagery can separate — lists what's here instead.
  void _expandCluster(List<MapRecord> cell) {
    final maxZ = activeImagery.maxZoom.toDouble();
    final z = expansionZoomBy(cell, recordCoords, _zoom, maxZoom: maxZ);
    if (z == null) {
      _recordsHere(cell);
      return;
    }
    final (lat, lng) = centreOf(cell, recordCoords);
    _userMoved = true;
    setState(() {
      _lat = lat;
      _lng = lng;
      _zoom = z.clamp(4.0, maxZ + 0.99);
    });
  }

  /// The phone's "what's here" sheet, as a dialog: every record in the
  /// cell, pick one to open it.
  Future<void> _recordsHere(List<MapRecord> cell) async {
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('${cell.length} RECORDS HERE'),
        children: [
          for (final r in cell)
            if (r.id != null)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, r.id),
                child: Row(
                  children: [
                    Diamond(size: 8, color: Color(markFor(r.type).argb)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          if (r.observedAt != null &&
                              r.observedAt!.length >= 10)
                            r.observedAt!.substring(0, 10),
                          r.label ?? _cap(r.type),
                        ].join(' · '),
                        style: TextStyle(
                          fontFamily: Type.serif,
                          fontSize: 13.5,
                          color: Press.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
    if (id == null || !mounted) return;
    setState(() {
      _selectedId = id;
      _closeFeature();
      _closeSite();
    });
  }

  // ── species groups ───────────────────────────────────────────────

  List<_SpeciesGroup> get _groups {
    final s = _layers;
    if (s == null) return const [];
    final byKey = <String, _SpeciesGroup>{};
    for (final r in s.records) {
      final key = r.label ?? '__type:${r.type}';
      (byKey[key] ??= _SpeciesGroup(
        key,
        r.label ?? _cap(r.type),
        r.type,
        [],
      )).records.add(r);
    }
    final out = byKey.values.toList()
      ..sort((a, b) {
        final byCount = b.records.length.compareTo(a.records.length);
        return byCount != 0
            ? byCount
            : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    return out;
  }

  /// Fly the camera to one mark (Austin: "click on the exact plant, and
  /// the map will take you to it").
  void _flyTo(double lat, double lng, {double? zoom}) {
    _userMoved = true;
    setState(() {
      _lat = lat;
      _lng = lng;
      if (zoom != null) _zoom = zoom;
    });
  }

  /// Frame every mark of one species — the per-row LOCATE.
  void _fitGroup(List<MapRecord> rs) {
    if (rs.isEmpty) return;
    final b = merc.LatLngBounds.ofPoints([for (final r in rs) (r.lat, r.lng)]);
    if (b == null) return;
    final bb = b.pad(0.35);
    _userMoved = true;
    setState(() {
      _lat = (bb.north + bb.south) / 2;
      _lng = (bb.east + bb.west) / 2;
      _zoom = merc
          .zoomFor(
            bb,
            _lastLayoutSize.width,
            _lastLayoutSize.height,
            maxZoom: activeImagery.maxZoom,
          )
          .toDouble();
    });
  }

  /// Fly to typed coordinates — "search by GPS" (Austin, 2026-09-04).
  /// Accepts "30.2617, -97.7281" and close variants.
  Future<void> _gotoCoords() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('GO TO COORDINATES'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'latitude, longitude'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('GO'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null) return;
    final m = RegExp(r'(-?\d+(?:\.\d+)?)[,;\s]+(-?\d+(?:\.\d+)?)')
        .firstMatch(text);
    if (m == null) return;
    final lat = double.parse(m.group(1)!);
    final lng = double.parse(m.group(2)!);
    if (lat.abs() > 90 || lng.abs() > 180) return;
    _userMoved = true;
    setState(() {
      _lat = lat;
      _lng = lng;
      _zoom = (activeImagery.maxZoom - 1).toDouble();
    });
  }

  // ── hit test ─────────────────────────────────────────────────────

  void _onTapUp(TapUpDetails d, Size size) {
    final s = _layers;
    if (s == null) return;
    String? bestRecord;
    String? bestFeature;
    String? bestSite;
    List<MapRecord>? bestCluster;
    var bestD = 16.0; // px
    final (lit, dimmed) = _clustersFor(s);
    for (final cell in lit.followedBy(dimmed)) {
      final double x, y;
      if (cell.length > 1) {
        final (lat, lng) = centreOf(cell, recordCoords);
        (x, y) = _screenOf(lat, lng, size);
      } else {
        final r = cell.single;
        if (r.id == null) continue;
        (x, y) = _screenOf(r.lat, r.lng, size);
      }
      final dist = (Offset(x, y) - d.localPosition).distance;
      if (dist < bestD) {
        bestD = dist;
        bestCluster = cell.length > 1 ? cell : null;
        bestRecord = cell.length > 1 ? null : cell.single.id;
        bestFeature = null;
      }
    }
    // Features are clickable here too — "can't even access it on the
    // desktop" (Austin, 2026-09-04).
    for (final f in s.features) {
      if (f.id == null) continue;
      try {
        final g = jsonDecode(f.geojson) as Map<String, dynamic>;
        if (g['type'] != 'Point') continue;
        final coords = g['coordinates'] as List;
        final (x, y) = _screenOf(
          (coords[1] as num).toDouble(),
          (coords[0] as num).toDouble(),
          size,
        );
        final dist = (Offset(x, y) - d.localPosition).distance;
        if (dist < bestD) {
          bestD = dist;
          bestFeature = f.id;
          bestRecord = null;
          bestCluster = null;
        }
      } catch (e, st) {
        Diag.report(e, st, where: 'DeskMapWorkspace._onTapUp');
      }
    }
    // Monitoring sites (D-033): the stake opens its panel.
    for (final site in s.sites) {
      final (x, y) = _screenOf(site.lat, site.lng, size);
      final dist = (Offset(x, y) - d.localPosition).distance;
      if (dist < bestD) {
        bestD = dist;
        bestSite = site.id;
        bestFeature = null;
        bestRecord = null;
        bestCluster = null;
      }
    }
    if (bestCluster != null) {
      _expandCluster(bestCluster);
    } else if (bestRecord != null) {
      setState(() {
        _selectedId = bestRecord;
        _closeFeature();
        _closeSite();
      });
    } else if (bestFeature != null) {
      setState(() {
        _selectedFeatureId = bestFeature;
        _selectedId = null;
        _closeSite();
      });
    } else if (bestSite != null) {
      setState(() {
        _selectedSiteId = bestSite;
        _selectedId = null;
        _closeFeature();
      });
    }
  }
}
