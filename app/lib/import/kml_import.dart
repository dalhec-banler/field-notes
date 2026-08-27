import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// KML/KMZ import (spec §6): parse Placemarks into geometry the review step
/// can map onto zones and features before anything is committed.
class KmlPlacemark {
  KmlPlacemark({
    required this.name,
    required this.description,
    required this.geometryType, // 'Point' | 'LineString' | 'Polygon' | 'MultiPolygon'
    required this.geojson,
    this.folder,
  });

  final String name;
  final String? description;
  final String geometryType;
  final String geojson;

  /// Folder path in the KML document, e.g. 'Zones/Riparian' — a strong hint
  /// for the review step's zone-vs-feature suggestion.
  final String? folder;
}

/// KMZ is a zipped KML (spec §6). Finds the first .kml entry.
List<KmlPlacemark> parseKmz(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive.files) {
    if (file.isFile && file.name.toLowerCase().endsWith('.kml')) {
      return parseKml(utf8.decode(file.content as List<int>));
    }
  }
  throw const FormatException('KMZ contains no .kml document');
}

List<KmlPlacemark> parseKml(String xmlText) {
  final doc = XmlDocument.parse(xmlText);
  final placemarks = <KmlPlacemark>[];

  for (final pm in doc.findAllElements('Placemark')) {
    final name = _childText(pm, 'name') ?? 'Untitled';
    final description = _childText(pm, 'description');
    final folder = _folderPath(pm);
    final geometry = _extractGeometry(pm);
    if (geometry == null) continue;
    placemarks.add(KmlPlacemark(
      name: name,
      description: description,
      geometryType: geometry.$1,
      geojson: geometry.$2,
      folder: folder,
    ));
  }
  return placemarks;
}

String? _childText(XmlElement parent, String tag) {
  for (final el in parent.childElements) {
    if (el.localName == tag) {
      final t = el.innerText.trim();
      return t.isEmpty ? null : t;
    }
  }
  return null;
}

String? _folderPath(XmlElement pm) {
  final parts = <String>[];
  XmlElement? node = pm.parentElement;
  while (node != null) {
    if (node.localName == 'Folder' || node.localName == 'Document') {
      final n = _childText(node, 'name');
      if (n != null) parts.insert(0, n);
    }
    node = node.parentElement;
  }
  return parts.isEmpty ? null : parts.join('/');
}

/// Returns (geometryType, geojson) or null when the Placemark has no
/// supported geometry.
(String, String)? _extractGeometry(XmlElement pm) {
  final point = pm.findElements('Point').firstOrNull;
  if (point != null) {
    final coords = _coords(point);
    if (coords.isEmpty) return null;
    return ('Point', jsonEncode({'type': 'Point', 'coordinates': coords.first}));
  }

  final line = pm.findElements('LineString').firstOrNull;
  if (line != null) {
    final coords = _coords(line);
    if (coords.length < 2) return null;
    return (
      'LineString',
      jsonEncode({'type': 'LineString', 'coordinates': coords})
    );
  }

  final polygon = pm.findElements('Polygon').firstOrNull;
  if (polygon != null) {
    final rings = _polygonRings(polygon);
    if (rings == null) return null;
    return ('Polygon', jsonEncode({'type': 'Polygon', 'coordinates': rings}));
  }

  final multi = pm.findElements('MultiGeometry').firstOrNull;
  if (multi != null) {
    final polys = <List<List<List<double>>>>[];
    for (final p in multi.findElements('Polygon')) {
      final rings = _polygonRings(p);
      if (rings != null) polys.add(rings);
    }
    if (polys.length == 1) {
      return ('Polygon', jsonEncode({'type': 'Polygon', 'coordinates': polys.first}));
    }
    if (polys.isNotEmpty) {
      return (
        'MultiPolygon',
        jsonEncode({'type': 'MultiPolygon', 'coordinates': polys})
      );
    }
    // Fall back to first point/line inside the MultiGeometry.
    for (final tag in ['Point', 'LineString']) {
      final el = multi.findElements(tag).firstOrNull;
      if (el != null) {
        final coords = _coords(el);
        if (coords.isEmpty) continue;
        return tag == 'Point'
            ? ('Point', jsonEncode({'type': 'Point', 'coordinates': coords.first}))
            : ('LineString', jsonEncode({'type': 'LineString', 'coordinates': coords}));
      }
    }
  }
  return null;
}

List<List<List<double>>>? _polygonRings(XmlElement polygon) {
  final outer = polygon
      .findElements('outerBoundaryIs')
      .firstOrNull
      ?.findElements('LinearRing')
      .firstOrNull;
  if (outer == null) return null;
  final outerCoords = _coords(outer);
  if (outerCoords.length < 4) return null;
  final rings = [outerCoords];
  for (final inner in polygon.findElements('innerBoundaryIs')) {
    final ring = inner.findElements('LinearRing').firstOrNull;
    if (ring == null) continue;
    final coords = _coords(ring);
    if (coords.length >= 4) rings.add(coords);
  }
  return rings;
}

/// KML coordinates: whitespace-separated `lon,lat[,alt]` tuples.
/// GeoJSON positions keep [lng, lat] order; altitude is dropped.
///
/// The spec forbids whitespace inside a tuple, but hand-edited and
/// Google-Earth-exported files often carry `lon, lat` with a space after
/// the comma; those were silently dropped (audit M15). Whitespace around
/// commas is collapsed before the tuples are split.
List<List<double>> _coords(XmlElement geometryElement) {
  final text = geometryElement
      .findElements('coordinates')
      .firstOrNull
      ?.innerText
      .replaceAll(RegExp(r'\s*,\s*'), ',')
      .trim();
  if (text == null || text.isEmpty) return [];
  final result = <List<double>>[];
  for (final tuple in text.split(RegExp(r'\s+'))) {
    final parts = tuple.split(',');
    if (parts.length < 2) continue;
    final lng = double.tryParse(parts[0]);
    final lat = double.tryParse(parts[1]);
    if (lng == null || lat == null) continue;
    result.add([lng, lat]);
  }
  return result;
}

/// GeoJSON import (spec §6): a FeatureCollection (or single Feature /
/// geometry) mapped onto the same placemark model the review step already
/// understands, so KML, KMZ and GeoJSON share one path to zones/features.
List<KmlPlacemark> parseGeoJson(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('not a GeoJSON object');
  }
  final features = <Map<String, dynamic>>[];
  switch (decoded['type']) {
    case 'FeatureCollection':
      for (final f in (decoded['features'] as List? ?? const [])) {
        if (f is Map<String, dynamic>) features.add(f);
      }
    case 'Feature':
      features.add(decoded);
    default:
      // Bare geometry.
      features.add({'type': 'Feature', 'geometry': decoded, 'properties': {}});
  }

  final out = <KmlPlacemark>[];
  var n = 0;
  for (final f in features) {
    final geometry = f['geometry'];
    if (geometry is! Map<String, dynamic>) continue;
    final type = geometry['type'] as String?;
    if (type == null) continue;
    final props = (f['properties'] as Map?)?.cast<String, dynamic>() ?? {};
    n++;
    String? pick(List<String> keys) {
      for (final k in keys) {
        final v = props[k];
        if (v != null && '$v'.trim().isNotEmpty) return '$v'.trim();
      }
      return null;
    }

    // Multi-point / multi-line: one placemark per part, like the KML path.
    if (type == 'MultiPoint' || type == 'MultiLineString') {
      final partType = type == 'MultiPoint' ? 'Point' : 'LineString';
      final coords = geometry['coordinates'] as List? ?? const [];
      for (var i = 0; i < coords.length; i++) {
        out.add(KmlPlacemark(
          name: '${pick(['name', 'Name', 'title', 'label']) ?? 'Feature $n'}'
              '${coords.length > 1 ? ' ${i + 1}' : ''}',
          description: pick(['description', 'desc', 'notes']),
          geometryType: partType,
          geojson: jsonEncode({'type': partType, 'coordinates': coords[i]}),
          folder: pick(['folder', 'layer', 'type', 'zone_type']),
        ));
      }
      continue;
    }
    if (!const {'Point', 'LineString', 'Polygon', 'MultiPolygon'}
        .contains(type)) {
      continue;
    }
    out.add(KmlPlacemark(
      name: pick(['name', 'Name', 'title', 'label']) ?? 'Feature $n',
      description: pick(['description', 'desc', 'notes']),
      geometryType: type,
      geojson: jsonEncode(geometry),
      folder: pick(['folder', 'layer', 'type', 'zone_type']),
    ));
  }
  return out;
}
