import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

/// Tilt-compensated compass heading from accelerometer + magnetometer.
/// Classic sensor-fusion formula; adequate for photo-point aiming (±5°).
class CompassStream {
  CompassStream() {
    _accSub = accelerometerEventStream().listen((e) {
      _ax = e.x;
      _ay = e.y;
      _az = e.z;
      _emit();
    });
    _magSub = magnetometerEventStream().listen((e) {
      _mx = e.x;
      _my = e.y;
      _mz = e.z;
      _emit();
    });
  }

  final _controller = StreamController<double>.broadcast();
  late final StreamSubscription _accSub;
  late final StreamSubscription _magSub;
  double _ax = 0, _ay = 0, _az = 9.8;
  double _mx = 0, _my = 0, _mz = 0;
  double? _smoothed;

  Stream<double> get headingDeg => _controller.stream;

  void _emit() {
    // Normalize gravity.
    final gNorm = math.sqrt(_ax * _ax + _ay * _ay + _az * _az);
    if (gNorm == 0) return;
    final gx = _ax / gNorm, gy = _ay / gNorm, gz = _az / gNorm;

    // Horizontal magnetic components (E = M × G, N = G × E).
    final ex = _my * gz - _mz * gy;
    final ey = _mz * gx - _mx * gz;
    final ez = _mx * gy - _my * gx;
    final eNorm = math.sqrt(ex * ex + ey * ey + ez * ez);
    if (eNorm == 0) return;
    final nx = gy * ez / eNorm - gz * ey / eNorm;
    final ny = gz * ex / eNorm - gx * ez / eNorm;

    var heading = math.atan2(ex / eNorm, nx) * 180 / math.pi;
    // Device Y axis points out the top; camera looks out the back (-Z), which
    // in portrait shares the top-of-device azimuth.
    heading = (heading + 360) % 360;
    // ignore: unused_local_variable
    final _ = ny;

    // Exponential smoothing with wraparound handling.
    final prev = _smoothed;
    if (prev == null) {
      _smoothed = heading;
    } else {
      var delta = heading - prev;
      if (delta > 180) delta -= 360;
      if (delta < -180) delta += 360;
      _smoothed = (prev + delta * 0.15 + 360) % 360;
    }
    _controller.add(_smoothed!);
  }

  void dispose() {
    _accSub.cancel();
    _magSub.cancel();
    _controller.close();
  }
}

/// Smallest signed angular difference a→b in degrees (−180, 180].
double angleDiffDeg(double a, double b) {
  var d = (b - a) % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}
