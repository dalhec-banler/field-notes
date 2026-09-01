import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../map/basemap_style.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Adjust a record's location by hand: pan the imagery under a fixed
/// crosshair and save where it lands (Austin, 2026-08-31: wrong-GPS
/// captures were stuck where the phone guessed).
///
/// Deliberately a crosshair, not a draggable pin — panning the map under a
/// fixed mark is steadier under a thumb than dragging a marker, and it's
/// the pattern every ride-share app has already taught. Imagery-only style:
/// no loopback server to stand up, and tracing against the actual pixels is
/// the point. Offline the imagery won't draw — the coordinates readout
/// still works, but this screen is honest about wanting signal.
class MovePinScreen extends StatefulWidget {
  const MovePinScreen({super.key, required this.lat, required this.lng});

  final double lat;
  final double lng;

  @override
  State<MovePinScreen> createState() => _MovePinScreenState();
}

class _MovePinScreenState extends State<MovePinScreen> {
  MapLibreMapController? _controller;
  LatLng _target = const LatLng(0, 0);

  @override
  void initState() {
    super.initState();
    _target = LatLng(widget.lat, widget.lng);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Move the pin'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _target),
            child: const Text('SAVE HERE'),
          ),
        ],
      ),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: basemapStyle(), // imagery-only
            initialCameraPosition: CameraPosition(
              target: LatLng(widget.lat, widget.lng),
              zoom: 19,
            ),
            trackCameraPosition: true,
            rotateGesturesEnabled: false,
            tiltGesturesEnabled: false,
            onMapCreated: (c) => _controller = c,
            onCameraIdle: () {
              final pos = _controller?.cameraPosition;
              if (pos != null) setState(() => _target = pos.target);
            },
          ),
          // The crosshair: a diamond ring over dead centre, drawn cheap so
          // it never lags the map.
          IgnorePointer(
            child: Center(
              child: Transform.rotate(
                angle: 0.7853981633974483, // 45°
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    border: Border.all(color: Press.oxblood, width: 3),
                    color: Press.oxblood.withValues(alpha: 0.15),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: Metrics.gutter,
            right: Metrics.gutter,
            bottom: 18,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: Press.ink,
              child: MonoLabel(
                'PAN UNTIL THE MARK SITS ON THE SPOT · '
                '${_target.latitude.toStringAsFixed(5)}, '
                '${_target.longitude.toStringAsFixed(5)}',
                size: 9,
                spacing: 1.1,
                color: Press.paperRaised,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
