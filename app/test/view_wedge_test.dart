import 'package:field_notes/geo/view_wedge.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wedge is what makes a photo point legible on a map: it must point
/// where the camera points and widen as the lens gets shorter.
void main() {
  test('field of view widens as focal length shortens', () {
    expect(fovDegFor(13), greaterThan(fovDegFor(26)));
    expect(fovDegFor(26), greaterThan(fovDegFor(77)));
    // A phone main camera is roughly 70 degrees across.
    expect(fovDegFor(26), closeTo(70, 4));
  });

  test('a north-facing wedge reaches north of the station', () {
    final w = viewWedge(lat: 30.26, lng: -97.72, bearingDeg: 0, extentM: 100);
    final far = w.sublist(1, w.length - 1);
    expect(far.every((p) => p[1] > 30.26), isTrue, reason: 'all north');
    // Centre of the arc sits due north: longitude barely moves.
    final mid = far[far.length ~/ 2];
    expect(mid[0], closeTo(-97.72, 0.0005));
  });

  test('an east-facing wedge reaches east, and the axis leads it', () {
    final w = viewWedge(lat: 30.26, lng: -97.72, bearingDeg: 90, extentM: 100);
    expect(w.sublist(1, w.length - 1).every((p) => p[0] > -97.72), isTrue);
    final axis = viewAxis(
      lat: 30.26,
      lng: -97.72,
      bearingDeg: 90,
      extentM: 100,
    );
    expect(axis.first, [-97.72, 30.26]);
    expect(axis.last[0], greaterThan(-97.72));
    expect(axis.last[1], closeTo(30.26, 0.0005));
  });

  test('the ring closes on the station', () {
    final w = viewWedge(lat: 31.0, lng: -98.0, bearingDeg: 210);
    expect(w.first, w.last);
  });
}
