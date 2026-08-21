import 'dart:convert';

/// Minimal MapLibre style over a Protomaps vector basemap served from the
/// loopback tile server. No glyphs or sprites — every layer here renders
/// without font/icon assets, so the style is fully offline from day one.
/// Labels come later with bundled glyphs.
String basemapStyle({String? pmtilesUrl, String? tilesUrl, int maxZoom = 15}) {
  assert((pmtilesUrl == null) != (tilesUrl == null));
  final style = {
    'version': 8,
    'name': 'Field Notes offline',
    'sources': {
      'basemap': pmtilesUrl != null
          ? {'type': 'vector', 'url': pmtilesUrl}
          : {
              'type': 'vector',
              'tiles': [tilesUrl],
              'minzoom': 0,
              'maxzoom': maxZoom,
            },
    },
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': '#ede8e0'},
      },
      {
        'id': 'earth',
        'type': 'fill',
        'source': 'basemap',
        'source-layer': 'earth',
        'paint': {'fill-color': '#f3efe7'},
      },
      {
        'id': 'landcover',
        'type': 'fill',
        'source': 'basemap',
        'source-layer': 'landcover',
        'paint': {'fill-color': '#dfe8d8', 'fill-opacity': 0.6},
      },
      {
        'id': 'landuse',
        'type': 'fill',
        'source': 'basemap',
        'source-layer': 'landuse',
        'paint': {'fill-color': '#e3e0d4', 'fill-opacity': 0.5},
      },
      {
        'id': 'water',
        'type': 'fill',
        'source': 'basemap',
        'source-layer': 'water',
        'paint': {'fill-color': '#a8c8dc'},
      },
      {
        'id': 'waterway',
        'type': 'line',
        'source': 'basemap',
        'source-layer': 'water',
        'filter': [
          '==',
          ['geometry-type'],
          'LineString'
        ],
        'paint': {'line-color': '#a8c8dc', 'line-width': 1.2},
      },
      {
        'id': 'roads',
        'type': 'line',
        'source': 'basemap',
        'source-layer': 'roads',
        'paint': {
          'line-color': '#c9c4b8',
          'line-width': [
            'interpolate',
            ['linear'],
            ['zoom'],
            8,
            0.5,
            14,
            2.0,
            18,
            6.0
          ],
        },
      },
      {
        'id': 'buildings',
        'type': 'fill',
        'source': 'basemap',
        'source-layer': 'buildings',
        'paint': {'fill-color': '#d9d3c7'},
      },
      {
        'id': 'boundaries',
        'type': 'line',
        'source': 'basemap',
        'source-layer': 'boundaries',
        'paint': {
          'line-color': '#9a938a',
          'line-width': 1.0,
          'line-dasharray': [3, 2],
        },
      },
    ],
  };
  return jsonEncode(style);
}
