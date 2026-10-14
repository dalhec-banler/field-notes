part of '../map_tab.dart';

mixin _MapTabShapes on _MapTabFilter {
  /// Draw and adjust the boundary and zones on the imagery — the polygon
  /// editor (D-024 batch 1). Every save re-derives zone assignment.
  Future<void> _editShapes() async {
    final zones = await _zones.of(widget.property.id, byName: true);
    if (!mounted) return;
    final choice = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Press.paper,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.symmetric(vertical: 8),
          children: [
            ListTile(
              leading: Icon(Icons.crop_square_outlined),
              title: Text('Property boundary'),
              subtitle: Text(
                widget.property.boundaryGeojson == null
                    ? 'Not drawn yet'
                    : 'Adjust the outline',
              ),
              onTap: () => Navigator.pop(ctx, 'boundary'),
            ),
            for (final z in zones)
              ListTile(
                leading: Icon(Icons.hexagon_outlined),
                title: Text(z.name),
                subtitle: Text(
                  z.areaAcres == null
                      ? 'Zone'
                      : '${z.areaAcres!.toStringAsFixed(1)} ac',
                ),
                onTap: () => Navigator.pop(ctx, z),
              ),
            ListTile(
              leading: Icon(Icons.add),
              title: Text('New zone'),
              subtitle: Text('Tap three corners on the imagery to start'),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    // Open exactly where the map is looking: anything else reads as the
    // editor throwing you somewhere else (Austin, 2026-09-04).
    LatLng? target;
    double? zoom;
    final cam = _controller?.cameraPosition;
    if (cam != null) {
      target = cam.target;
      zoom = cam.zoom;
    }
    final c = target != null ? null : propertyCentre(widget.property);
    if (c != null) {
      target = LatLng(c[1], c[0]);
    } else {
      final mean = await _records.meanPosition(widget.property.id);
      if (mean != null) target = LatLng(mean.$1, mean.$2);
    }
    if (!mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => choice == 'boundary'
            ? PolygonEditorScreen.boundary(
                db: widget.db,
                property: widget.property,
                initialTarget: target,
                initialZoom: zoom,
              )
            : choice == 'new'
            ? PolygonEditorScreen.newZone(
                db: widget.db,
                property: widget.property,
                initialTarget: target,
                initialZoom: zoom,
              )
            : PolygonEditorScreen.zone(
                db: widget.db,
                property: widget.property,
                zone: choice as Zone,
                initialTarget: target,
                initialZoom: zoom,
              ),
      ),
    );
    if (saved == true && mounted) setState(() {});
  }
}
