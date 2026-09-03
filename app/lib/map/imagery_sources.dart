/// Where satellite imagery comes from (Austin, 2026-09-03: "we are looking
/// at pixelated garbage" — USGS's national tile cache stops at zoom 16).
///
/// USGS stays the default and the always-there fallback: public domain, no
/// key, no terms to honour, safe to capture offline later. Esri World
/// Imagery goes several zooms deeper over most of the US and is free to
/// *display* with attribution, but its terms don't allow bulk offline
/// download — so it is a viewing source only, never a capture source.
///
/// `activeImagery` is process-wide state decided at startup from prefs,
/// the same pattern as the skin (D-023): styles and plates read it, and
/// changing it rebuilds the map rather than mutating a live style.
library;

class ImagerySource {
  const ImagerySource({
    required this.id,
    required this.label,
    required this.template,
    required this.maxZoom,
    required this.attribution,
  });

  final String id;
  final String label;

  /// XYZ template with {z}/{x}/{y} placeholders.
  final String template;

  /// Deepest zoom the service caches. The map and the plate both frame
  /// against this.
  final int maxZoom;

  final String attribution;
}

const usgsImagery = ImagerySource(
  id: 'usgs',
  label: 'USGS — public domain',
  template: 'https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}',
  maxZoom: 16,
  attribution: 'USGS The National Map',
);

const esriImagery = ImagerySource(
  id: 'esri',
  label: 'Esri World Imagery — sharper',
  template: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
  maxZoom: 19,
  attribution: 'Esri, Maxar, Earthstar Geographics',
);

const imagerySources = [usgsImagery, esriImagery];

ImagerySource imageryById(String? id) =>
    imagerySources.where((s) => s.id == id).firstOrNull ?? usgsImagery;

/// The source in use, set once at startup from prefs and only ever changed
/// together with a map/style rebuild.
ImagerySource activeImagery = usgsImagery;
