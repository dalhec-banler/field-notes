import 'dart:convert';

import '../map/record_ink.dart';
import 'map_document.dart';
import 'map_plate.dart';

/// A self-contained interactive map for the website or a partner's inbox
/// (D-024). One HTML file: MapLibre GL JS from a CDN, USGS imagery, and
/// the property's GeoJSON embedded. No account, no key, no server of ours.
///
/// The same [PlateSubject]/[PlateLayers] the raster plate uses, so what you
/// preview is what you publish — and the records layer is opt-in for the
/// same reason (hard rule 3).
class MapHtml {
  static const maplibreVersion = '4.7.1';

  static String build(
    PlateSubject subject, {
    PlateLayers layers = const PlateLayers(),
    String? title,

    /// The document's date line ([MapDocument.dateLine]) so an explicitly
    /// set date survives into the HTML like it does into PDF and DOCX.
    String? dateLine,
    String attribution = 'Imagery: USGS The National Map · Field Notes',
  }) {
    final t = _esc(title ?? subject.propertyName);
    final bounds = MapPlate.frameBounds(subject, layers);

    Map<String, dynamic> fc(List<Map<String, dynamic>> features) => {
      'type': 'FeatureCollection',
      'features': features,
    };

    final zones = fc([
      if (layers.zones)
        for (var i = 0; i < subject.zones.length; i++)
          {
            'type': 'Feature',
            'properties': {
              'name': subject.zones[i].name,
              'acres': subject.zones[i].areaAcres,
              'color': _hex(
                subject.zones[i].colorHex ??
                    _argbToHex(
                      PlateInk.zoneFills[i % PlateInk.zoneFills.length],
                    ),
              ),
            },
            'geometry': jsonDecode(subject.zones[i].geojson),
          },
    ]);
    final boundary = fc([
      if (layers.boundary && subject.boundaryGeojson != null)
        {
          'type': 'Feature',
          'properties': {'name': 'Property boundary'},
          'geometry': jsonDecode(subject.boundaryGeojson!),
        },
    ]);
    final features = fc([
      if (layers.features)
        for (final f in subject.features)
          {
            'type': 'Feature',
            'properties': {
              'name': f.name,
              'class': f.featureClass,
              'color': _hex(
                _argbToHex(switch (f.featureClass) {
                  'problem' => PlateInk.oxblood,
                  'infrastructure' => PlateInk.ink,
                  _ => PlateInk.river,
                }),
              ),
            },
            'geometry': jsonDecode(f.geojson),
          },
    ]);
    final records = fc([
      if (layers.records)
        for (final r in subject.records)
          {
            'type': 'Feature',
            'properties': {
              'type': r.type,
              'label': r.label ?? r.type,
              'color': cssHex(markFor(r.type).argb),
            },
            'geometry': {
              'type': 'Point',
              'coordinates': [r.lng, r.lat],
            },
          },
    ]);
    final tracks = fc([
      if (layers.tracks)
        for (final tr in subject.tracks)
          {
            'type': 'Feature',
            'properties': {'label': tr.label ?? 'Walked track'},
            'geometry': jsonDecode(tr.geojson),
          },
    ]);

    final legend = <(String, String)>[
      if (layers.boundary && subject.boundaryGeojson != null)
        (_hex(_argbToHex(PlateInk.oxblood)), 'Property boundary'),
      if (layers.zones)
        for (var i = 0; i < subject.zones.length; i++)
          (
            _hex(
              subject.zones[i].colorHex ??
                  _argbToHex(PlateInk.zoneFills[i % PlateInk.zoneFills.length]),
            ),
            subject.zones[i].name,
          ),
      if (layers.tracks && subject.tracks.isNotEmpty)
        (_hex(_argbToHex(PlateInk.ink)), 'Walked track'),
      if (layers.records && subject.records.isNotEmpty)
        for (final t in {for (final r in subject.records) r.type})
          (
            cssHex(markFor(t).argb),
            '${t[0].toUpperCase()}${t.substring(1)} record',
          ),
    ];

    final legendHtml = [
      for (final (color, label) in legend)
        '<div class="row"><span class="sw" style="background:$color"></span>${_esc(label)}</div>',
    ].join();

    return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$t</title>
<link href="https://unpkg.com/maplibre-gl@$maplibreVersion/dist/maplibre-gl.css" rel="stylesheet">
<script src="https://unpkg.com/maplibre-gl@$maplibreVersion/dist/maplibre-gl.js"></script>
<style>
  html,body{margin:0;height:100%;background:#F7F6F2;font-family:ui-monospace,Menlo,monospace;color:#1B1813}
  #map{position:absolute;inset:0}
  .plate{position:absolute;top:14px;left:14px;background:rgba(247,246,242,.95);border:1.5px solid #1B1813;border-left:5px solid #8B2E22;padding:10px 16px;max-width:60%}
  .plate h1{margin:0;font-size:18px;letter-spacing:.06em}
  .plate p{margin:4px 0 0;font-size:11px;color:#6B655C}
  .legend{position:absolute;top:14px;right:14px;background:rgba(247,246,242,.95);border:1.5px solid #1B1813;padding:8px 12px;font-size:11px}
  .legend .row{display:flex;align-items:center;gap:8px;line-height:18px}
  .legend .sw{display:inline-block;width:12px;height:12px}
  .attr{position:absolute;bottom:10px;right:10px;background:rgba(247,246,242,.85);font-size:9px;padding:3px 6px;color:#6B655C}
  .maplibregl-popup-content{font-family:inherit;font-size:12px;border:1.5px solid #1B1813;border-radius:0}
</style>
</head>
<body>
<div id="map"></div>
<div class="plate"><h1>$t</h1><p>${_esc(dateLine ?? _today())}</p></div>
${legend.isEmpty ? '' : '<div class="legend">$legendHtml</div>'}
<div class="attr">${_esc(attribution)}</div>
<script>
const DATA = {
  bounds: [[${bounds.west}, ${bounds.south}], [${bounds.east}, ${bounds.north}]],
  zones: ${jsonEncode(zones)},
  boundary: ${jsonEncode(boundary)},
  features: ${jsonEncode(features)},
  records: ${jsonEncode(records)},
  tracks: ${jsonEncode(tracks)}
};
const map = new maplibregl.Map({
  container: 'map',
  style: {
    version: 8,
    sources: { imagery: { type: 'raster', tiles: ['$usgsImageryTemplate'], tileSize: 256, maxzoom: 16, attribution: 'USGS The National Map' } },
    layers: [{ id: 'imagery', type: 'raster', source: 'imagery' }]
  },
  bounds: DATA.bounds,
  fitBoundsOptions: { padding: 24 },
  attributionControl: false
});
map.addControl(new maplibregl.NavigationControl({ showCompass: true }), 'bottom-left');
map.addControl(new maplibregl.ScaleControl({ unit: 'imperial' }), 'bottom-left');
map.on('load', () => {
  map.addSource('zones', { type: 'geojson', data: DATA.zones });
  map.addLayer({ id: 'zones-fill', type: 'fill', source: 'zones', paint: { 'fill-color': ['get', 'color'], 'fill-opacity': 0.3 } });
  map.addLayer({ id: 'zones-line', type: 'line', source: 'zones', paint: { 'line-color': ['get', 'color'], 'line-width': 2 } });
  map.addSource('boundary', { type: 'geojson', data: DATA.boundary });
  map.addLayer({ id: 'boundary-halo', type: 'line', source: 'boundary', paint: { 'line-color': '#FFFFFF', 'line-width': 6, 'line-opacity': 0.8 } });
  map.addLayer({ id: 'boundary-line', type: 'line', source: 'boundary', paint: { 'line-color': '#8B2E22', 'line-width': 3 } });
  map.addSource('tracks', { type: 'geojson', data: DATA.tracks });
  map.addLayer({ id: 'tracks-halo', type: 'line', source: 'tracks', paint: { 'line-color': '#FFFFFF', 'line-width': 5, 'line-opacity': 0.7 } });
  map.addLayer({ id: 'tracks-line', type: 'line', source: 'tracks', paint: { 'line-color': '#1B1813', 'line-width': 2 } });
  map.addSource('features', { type: 'geojson', data: DATA.features });
  map.addLayer({ id: 'features-fill', type: 'fill', source: 'features', filter: ['==', ['geometry-type'], 'Polygon'], paint: { 'fill-color': ['get', 'color'], 'fill-opacity': 0.25 } });
  map.addLayer({ id: 'features-line', type: 'line', source: 'features', filter: ['in', ['geometry-type'], ['literal', ['LineString', 'Polygon']]], paint: { 'line-color': ['get', 'color'], 'line-width': 2.5 } });
  map.addLayer({ id: 'features-pt', type: 'circle', source: 'features', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 7, 'circle-color': ['get', 'color'], 'circle-stroke-color': '#FFFFFF', 'circle-stroke-width': 2 } });
  map.addSource('records', { type: 'geojson', data: DATA.records, cluster: true, clusterRadius: 36, clusterMaxZoom: 19 });
  map.addLayer({ id: 'records-cluster', type: 'circle', source: 'records', filter: ['has', 'point_count'], paint: { 'circle-radius': ['step', ['get', 'point_count'], 11, 10, 14, 50, 18], 'circle-color': '#1B1813', 'circle-stroke-color': '#FFFFFF', 'circle-stroke-width': 2 } });
  map.addLayer({ id: 'records-count', type: 'symbol', source: 'records', filter: ['has', 'point_count'], layout: { 'text-field': ['get', 'point_count_abbreviated'], 'text-size': 11, 'text-font': ['Open Sans Bold', 'Arial Unicode MS Bold'] }, paint: { 'text-color': '#F7F6F2' } });
  map.addLayer({ id: 'records-pt', type: 'circle', source: 'records', filter: ['!', ['has', 'point_count']], paint: { 'circle-radius': 5.5, 'circle-color': ['get', 'color'], 'circle-stroke-color': '#FFFFFF', 'circle-stroke-width': 1.5 } });
  map.addLayer({ id: 'zones-label', type: 'symbol', source: 'zones', layout: { 'text-field': ['get', 'name'], 'text-size': 12, 'text-font': ['Open Sans Bold', 'Arial Unicode MS Bold'] }, paint: { 'text-color': '#1B1813', 'text-halo-color': '#F7F6F2', 'text-halo-width': 1.5 } });

  const popup = (e, html) => new maplibregl.Popup({ closeButton: false }).setLngLat(e.lngLat).setHTML(html).addTo(map);
  map.on('click', 'zones-fill', e => { const p = e.features[0].properties; popup(e, '<b>' + p.name + '</b>' + (p.acres ? '<br>' + Number(p.acres).toFixed(1) + ' ac' : '')); });
  map.on('click', 'features-pt', e => { const p = e.features[0].properties; popup(e, '<b>' + p.name + '</b><br>' + p.class); });
  map.on('click', 'records-pt', e => { const p = e.features[0].properties; popup(e, '<b>' + p.label + '</b><br>' + p.type); });
  map.on('click', 'records-cluster', e => {
    const f = map.queryRenderedFeatures(e.point, { layers: ['records-cluster'] })[0];
    map.getSource('records').getClusterExpansionZoom(f.properties.cluster_id).then(z => map.easeTo({ center: f.geometry.coordinates, zoom: z }));
  });
  for (const id of ['zones-fill', 'features-pt', 'records-pt', 'records-cluster']) {
    map.on('mouseenter', id, () => map.getCanvas().style.cursor = 'pointer');
    map.on('mouseleave', id, () => map.getCanvas().style.cursor = '');
  }
});
</script>
</body>
</html>
''';
  }

  static String _esc(String s) => escapeXml(s);

  static String _today() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  static String _argbToHex(int argb) => argbToCssHex(argb);

  static String _hex(String h) => h.startsWith('#') ? h : '#$h';
}
