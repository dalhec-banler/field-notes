part of '../map_plate.dart';

/// EPSG:3857 bbox string for the frame's bounds.
String _mercBboxOf(LatLngBounds b) {
  const r = 6378137.0;
  double mx(double lon) => lon * math.pi / 180 * r;
  double my(double lat) =>
      r * math.log(math.tan(math.pi / 4 + lat * math.pi / 360));
  return '${mx(b.west)},${my(b.south)},${mx(b.east)},${my(b.north)}';
}

// ── geometry helpers ───────────────────────────────────────────────

Map<String, dynamic>? _decode(String? geojson) {
  if (geojson == null || geojson.isEmpty) return null;
  try {
    final v = jsonDecode(geojson);
    if (v is Map<String, dynamic>) {
      if (v['type'] == 'Feature') {
        return v['geometry'] as Map<String, dynamic>?;
      }
      return v;
    }
  } catch (e, st) {
    Diag.report(e, st, where: 'MapPlate._decode');
  }
  return null;
}

void _walkCoords(
  dynamic node,
  void Function(double lat, double lng) f,
) {
  if (node is Map) {
    final coords = node['coordinates'];
    if (coords != null) _walkCoords(coords, f);
    final geoms = node['geometries'];
    if (geoms is List) {
      for (final g in geoms) {
        _walkCoords(g, f);
      }
    }
    return;
  }
  if (node is List) {
    if (node.length >= 2 && node[0] is num && node[1] is num) {
      f((node[1] as num).toDouble(), (node[0] as num).toDouble());
    } else {
      for (final n in node) {
        _walkCoords(n, f);
      }
    }
  }
}

ui.Path? _polygonPath(PlateFrame frame, String geojson) {
  final g = _decode(geojson);
  if (g == null) return null;
  final path = ui.Path();
  void ring(List r) {
    for (var i = 0; i < r.length; i++) {
      final c = r[i] as List;
      final (x, y) = frame.toPlate(
        (c[1] as num).toDouble(),
        (c[0] as num).toDouble(),
      );
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    path.close();
  }

  switch (g['type']) {
    case 'Polygon':
      for (final r in g['coordinates'] as List) {
        ring(r as List);
      }
    case 'MultiPolygon':
      for (final poly in g['coordinates'] as List) {
        for (final r in poly as List) {
          ring(r as List);
        }
      }
    default:
      return null;
  }
  path.fillType = ui.PathFillType.evenOdd;
  return path;
}

ui.Path? _linePath(PlateFrame frame, String geojson) {
  final g = _decode(geojson);
  if (g == null) return null;
  final path = ui.Path();
  void line(List pts) {
    for (var i = 0; i < pts.length; i++) {
      final c = pts[i] as List;
      final (x, y) = frame.toPlate(
        (c[1] as num).toDouble(),
        (c[0] as num).toDouble(),
      );
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
  }

  switch (g['type']) {
    case 'LineString':
      line(g['coordinates'] as List);
    case 'MultiLineString':
      for (final l in g['coordinates'] as List) {
        line(l as List);
      }
    default:
      return null;
  }
  return path;
}

/// Average of the outer ring — good enough to place a label.
(double, double)? _centroid(String geojson) {
  final g = _decode(geojson);
  if (g == null) return null;
  List? ring;
  if (g['type'] == 'Polygon') {
    ring = (g['coordinates'] as List).first as List;
  } else if (g['type'] == 'MultiPolygon') {
    ring = ((g['coordinates'] as List).first as List).first as List;
  }
  if (ring == null || ring.isEmpty) return null;
  var sx = 0.0, sy = 0.0;
  for (final c in ring) {
    sx += ((c as List)[0] as num).toDouble();
    sy += (c[1] as num).toDouble();
  }
  return (sy / ring.length, sx / ring.length);
}

int? _parseHex(String? hex) {
  if (hex == null) return null;
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  return int.tryParse(h, radix: 16);
}

String _cap(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

