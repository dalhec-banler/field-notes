part of '../map_tab.dart';

/// The ledger's filter as the map sees it, and the zone count.
mixin _MapTabFilter on _MapTabCore {
  void _onFilterChanged() {
    if (!mounted) return;
    if (_scope.recordFilter.consumeJump()) _fitFiltered();
    setState(() {});
  }

  /// Frame every record the filter keeps — the species jump's landing.
  Future<void> _fitFiltered() async {
    final rows = await _records.located(widget.property.id);
    final f = _scope.recordFilter;
    final pts = [
      for (final o in rows)
        if ((f.type == null || o.observationType == f.type) &&
            (f.taxonId == null || o.taxonId == f.taxonId) &&
            (f.zoneId == null || o.zoneId == f.zoneId))
          o,
    ];
    final controller = _controller;
    if (pts.isEmpty || controller == null || !mounted) return;
    if (pts.length == 1) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(pts.first.lat, pts.first.lng), 17),
      );
      return;
    }
    var minLat = pts.first.lat, maxLat = pts.first.lat;
    var minLng = pts.first.lng, maxLng = pts.first.lng;
    for (final o in pts) {
      if (o.lat < minLat) minLat = o.lat;
      if (o.lat > maxLat) maxLat = o.lat;
      if (o.lng < minLng) minLng = o.lng;
      if (o.lng > maxLng) maxLng = o.lng;
    }
    await controller.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        left: 60,
        top: 140,
        right: 60,
        bottom: 180,
      ),
    );
  }

  Future<void> _loadCounts() async {
    final zones = await _zones.of(widget.property.id);
    if (mounted) setState(() => _zoneCount = zones.length);
  }
}
