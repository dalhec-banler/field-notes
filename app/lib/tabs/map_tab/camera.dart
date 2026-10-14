part of '../map_tab.dart';

/// Flying the camera, and capturing the visible area for offline use.
mixin _MapTabCamera on _MapTabLayers {
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
    } catch (e, st) {
      Diag.report(e, st, where: 'MapTab._flyToProperty');
    }
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
    } catch (e, st) {
      Diag.report(e, st, where: 'MapTab._flyTo');
    }
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
}
