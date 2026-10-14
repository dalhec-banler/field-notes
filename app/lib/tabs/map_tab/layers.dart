part of '../map_tab.dart';

/// Layer toggles, the layers sheet and go-to-coordinates.
mixin _MapTabLayers on _MapTabShapes {
  /// Apply the sheet's [LayerVisibility] to the style, by the ids the map
  /// screen gave each kind ([mapLayerIds]). Zones are tried one id at a
  /// time (the source is absent on a place with none), tracks/features/
  /// photo points as a group, imagery on its own — the same tolerance as
  /// before the model existed.
  Future<void> _applyLayers() async {
    final c = _controller;
    if (c == null) return;
    final v = _visibility;
    for (final id in mapLayerIds[MapLayerKind.zones]!) {
      try {
        await c.setLayerVisibility(id, v.zones);
      } catch (e, st) {
        Diag.report(e, st, where: 'MapTab._applyLayers');
      }
    }
    try {
      for (final kind in const [
        MapLayerKind.tracks,
        MapLayerKind.features,
        MapLayerKind.photoPoints,
        MapLayerKind.protocolSites,
      ]) {
        for (final id in mapLayerIds[kind]!) {
          await c.setLayerVisibility(id, v.isOn(kind));
        }
      }
    } catch (e, st) {
      Diag.report(e, st, where: 'MapTab._applyLayers');
    }
    try {
      for (final id in mapLayerIds[MapLayerKind.imagery]!) {
        await c.setLayerVisibility(id, v.imagery);
      }
    } catch (e, st) {
      Diag.report(e, st, where: 'MapTab._applyLayers');
    }
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
                  _pill('photo points', _showPhotoPoints, () {
                    setSheet(() => _showPhotoPoints = !_showPhotoPoints);
                    setState(() {});
                    _applyLayers();
                  }),
                  _pill('monitoring sites', _showProtocolSites, () {
                    setSheet(() => _showProtocolSites = !_showProtocolSites);
                    setState(() {});
                    _applyLayers();
                  }),
                  _pill('go to…', false, () {
                    Navigator.of(ctx).pop();
                    _gotoCoords();
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
                        _showZones = true;
                        _showTracks = true;
                        _showFeatures = true;
                        _showPhotoPoints = true;
                        _showProtocolSites = true;
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

  /// Fly to typed coordinates — "search by GPS" (Austin, 2026-09-04).
  Future<void> _gotoCoords() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('GO TO COORDINATES'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
            decimal: true,
          ),
          decoration: const InputDecoration(hintText: 'latitude, longitude'),
          onSubmitted: (v) => Navigator.pop(dctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, controller.text),
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
    await _controller?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(lat, lng), 17),
    );
  }

  Widget _pill(String label, bool on, VoidCallback onTap, {Widget? swatch}) {
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (swatch != null) ...[
                Opacity(opacity: on ? 1 : 0.85, child: swatch),
                const SizedBox(width: 7),
              ],
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontFamily: Type.mono,
                  fontSize: 9.5,
                  letterSpacing: 1.4,
                  color: on ? Press.paper : Press.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
