import 'dart:convert';

import 'imagery_sources.dart';

/// Minimal MapLibre style over a Protomaps vector basemap served from the
/// loopback tile server. No glyphs or sprites — every layer here renders
/// without font/icon assets, so the style is fully offline from day one.
/// Labels come later with bundled glyphs.
String basemapStyle({
  String? pmtilesUrl,
  String? tilesUrl,
  int maxZoom = 15,
  String? satTemplate,
  int? satMaxZoom,
}) {
  // No offline archive yet: imagery alone still gives a usable map wherever
  // there's signal, and every overlay (boundary, zones, pins) still draws.
  final satelliteOnly = pmtilesUrl == null && tilesUrl == null;
  if (satelliteOnly) return _satelliteOnlyStyle();
  assert((pmtilesUrl == null) != (tilesUrl == null));
  final style = {
    'version': 8,
    'name': 'Field Notes offline',
    'sources': {
      // Online-only imagery layer, toggled from the map's Layers sheet.
      // USGS National Map imagery: public domain, no key. Offline capture
      // of imagery tiles is a later step.
      'satellite': {
        'type': 'raster',
        'tiles': [satTemplate ?? activeImagery.template],
        'tileSize': 256,
        'maxzoom': satMaxZoom ?? activeImagery.maxZoom,
        'attribution': activeImagery.attribution,
      },
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
          'LineString',
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
            6.0,
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
      // Imagery last in the base style: it covers the vector ground when
      // switched on, while every overlay added at runtime still draws on
      // top of it.
      {
        'id': 'satellite',
        'type': 'raster',
        'source': 'satellite',
        'layout': {'visibility': 'none'},
      },
    ],
  };
  return jsonEncode(style);
}

/// Imagery-only style for a phone with no offline basemap installed.
/// Same source id and layer id as the full style, so the Layers toggle
/// works identically.
String _satelliteOnlyStyle() => jsonEncode({
  'version': 8,
  'name': 'Field Notes imagery',
  'sources': {
    'satellite': {
      'type': 'raster',
      'tiles': [activeImagery.template],
      'tileSize': 256,
      'maxzoom': activeImagery.maxZoom,
      'attribution': activeImagery.attribution,
    },
  },
  'layers': [
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': '#ede8e0'},
    },
    {
      'id': 'satellite',
      'type': 'raster',
      'source': 'satellite',
      'layout': {'visibility': 'visible'},
    },
  ],
});
