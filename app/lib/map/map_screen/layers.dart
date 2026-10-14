part of '../map_screen.dart';

/// Sources and layers on the style: position, place overlays, pins. The
/// ids here are the ones the layers sheet switches ([mapLayerIds]).
mixin _MapScreenLayers on _MapScreenPosition {
  /// Current position: river-fill circle with a paper border and a soft
  /// ring (design §3.1 item 7) — drawn last so it sits above everything.
  Future<void> _addPositionLayer() async {
    final controller = _controller;
    if (controller == null) return;
    final seed = _fix;
    await controller.addGeoJsonSource(
      'me',
      seed != null ? _positionGeoJson(seed) : _emptyCollection,
    );
    // How well the phone knows where it is, drawn to scale on the ground
    // (design audit P3: accuracy was plumbed into the source and never
    // shown). A wide ring in the trees is the truth, not a defect.
    await controller.addFillLayer(
      'me',
      'me-accuracy',
      const FillLayerProperties(fillColor: '#1D6FE0', fillOpacity: 0.10),
      filter: [
        '==',
        ['geometry-type'],
        'Polygon',
      ],
    );
    await controller.addLineLayer(
      'me',
      'me-accuracy-edge',
      const LineLayerProperties(
        lineColor: '#1D6FE0',
        lineWidth: 1,
        lineOpacity: 0.35,
      ),
      filter: [
        '==',
        ['geometry-type'],
        'Polygon',
      ],
    );
    await controller.addImage('me-reticle', await positionReticle());
    await controller.addSymbolLayer(
      'me',
      'me-reticle',
      const SymbolLayerProperties(
        iconImage: 'me-reticle',
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
    );
    _positionLayerReady = true;
  }

  /// Property boundary, zone fills, tracks, features, photo points and
  /// observation pins, from the one layer set.
  Future<void> _addOverlays() async {
    final controller = _controller;
    final db = widget.db;
    final property = widget.property;
    if (controller == null || db == null || property == null) return;
    // A style (re)load drops every source, layer and image; forget what
    // was painted so the next paint pushes everything again.
    _recordLayersReady = false;
    _featureLayerReady = false;
    _photoPointLayerReady = false;
    _lastPainted = null;
    _lastPaintZoom = null;
    _badgeImages.clear();
    try {
      await _addPlaceOverlays(controller, property);
    } catch (e, st) {
      Diag.report(e, st, where: 'MapScreen._addOverlays');
      // Zones, boundary, photo points or features failing to draw must
      // not cost the record pins — those are what the map is for.
    }
    await _addRecordLayers(controller);
    // Push the set the place overlays loaded, now that every source
    // exists; the watch (which fires once on listen) follows every change
    // after it.
    final set = _layers;
    if (set != null) await _applyLayerSet(set);
    _watchLayers();
  }

  Future<void> _addPlaceOverlays(
    MapLibreMapController controller,
    Property property,
  ) async {
    final set = await _loadLayers(property);
    _layers = set;
    for (final layer in set.layers) {
      switch (layer) {
        case ZoneFills(:final zones) when zones.isNotEmpty:
          await controller.addGeoJsonSource('zones', {
            'type': 'FeatureCollection',
            'features': [
              for (final z in zones)
                {
                  'type': 'Feature',
                  'geometry': jsonDecode(z.geojson),
                  'properties': {'name': z.name},
                },
            ],
          });
          await controller.addFillLayer(
            'zones',
            'zones-fill',
            const FillLayerProperties(fillColor: '#7d9b76', fillOpacity: 0.25),
          );
          await controller.addLineLayer(
            'zones',
            'zones-line',
            const LineLayerProperties(lineColor: '#5c7a55', lineWidth: 1.5),
          );

        case BoundaryLine(:final geojson):
          await controller.addGeoJsonSource('boundary', {
            'type': 'Feature',
            'geometry': jsonDecode(geojson),
            'properties': <String, Object>{},
          });
          await controller.addLineLayer(
            'boundary',
            'boundary-line',
            // No lineDasharray: the plugin's Java property converter hits a
            // JNI toArray-on-null crash on dash arrays (Android 36).
            const LineLayerProperties(lineColor: '#8a3324', lineWidth: 2.5),
          );

        // Tracks (spec §4.13) as thin ink lines under the pins.
        case TrackLines(:final tracks) when tracks.isNotEmpty:
          await controller.addGeoJsonSource('tracks', {
            'type': 'FeatureCollection',
            'features': [
              for (final t in tracks)
                {
                  'type': 'Feature',
                  'geometry': jsonDecode(t.geojson),
                  'properties': {'id': t.id},
                },
            ],
          });
          await controller.addLineLayer(
            'tracks',
            'tracks-line',
            const LineLayerProperties(
              lineColor: '#2C2620',
              lineWidth: 2,
              lineOpacity: 0.55,
            ),
          );

        case FeatureMarks():
          await _addFeatureLayers(controller);

        case PhotoPointStations():
          await _addPhotoPointLayers(controller);

        case ImageryBase():
        case ZoneFills():
        case TrackLines():
        case ProtocolSiteMarks():
        case RecordMarks():
        case RecordClusters():
        case PositionMark():
          // Imagery is the style's own raster; records get their layers in
          // _addRecordLayers so they sit above everything else; protocol
          // sites are not drawn on the phone.
          break;
      }
    }
  }

  /// Features (springs, guzzlers, headcuts…): silhouettes by class, so
  /// they never read as records. Points are icons; lines and polygons
  /// draw in the class colour.
  Future<void> _addFeatureLayers(MapLibreMapController controller) async {
    for (final cls in ['natural', 'infrastructure', 'problem']) {
      await controller.addImage('feature-$cls', await featureMarker(cls));
    }
    // Record shape language (2026-09-03): built things are squares, trouble
    // is a triangle — same silhouettes as the Features layer, but in the
    // record layer's paper stroke at record-dot weight.
    for (final e in const {
      'infrastructure': 'obs-square-ink',
      'maintenance': 'obs-square-ochre',
      'problem': 'obs-triangle',
    }.entries) {
      await controller.addImage(e.value, await recordShapeMarker(e.key));
    }
    await controller.addGeoJsonSource('features', _emptyCollection);
    await controller.addFillLayer(
      'features',
      'features-fill',
      const FillLayerProperties(fillColor: ['get', 'color'], fillOpacity: 0.22),
      filter: [
        '==',
        ['geometry-type'],
        'Polygon',
      ],
    );
    await controller.addLineLayer(
      'features',
      'features-line',
      const LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 2.5),
      filter: [
        'in',
        ['geometry-type'],
        [
          'literal',
          ['LineString', 'Polygon'],
        ],
      ],
    );
    await controller.addSymbolLayer(
      'features',
      'features-pt',
      const SymbolLayerProperties(
        iconImage: ['get', 'icon'],
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      filter: [
        '==',
        ['geometry-type'],
        'Point',
      ],
      enableInteraction: true,
    );
    _featureLayerReady = true;
  }

  /// Photo points: the station, the ground it frames, and its axis — a
  /// monitoring station is a spot AND a direction AND a field of view
  /// (Austin, 2026-09-04).
  Future<void> _addPhotoPointLayers(MapLibreMapController controller) async {
    await controller.addImage('photo-point', await photoPointMarker());
    await controller.addGeoJsonSource('photopoints', _emptyCollection);
    await controller.addFillLayer(
      'photopoints',
      'pp-wedge',
      const FillLayerProperties(fillColor: '#D9A521', fillOpacity: 0.20),
      filter: [
        '==',
        ['geometry-type'],
        'Polygon',
      ],
    );
    await controller.addLineLayer(
      'photopoints',
      'pp-axis',
      const LineLayerProperties(
        lineColor: '#D9A521',
        lineWidth: 2,
        lineOpacity: 0.9,
      ),
      filter: [
        '==',
        ['geometry-type'],
        'LineString',
      ],
    );
    await controller.addSymbolLayer(
      'photopoints',
      'pp-pt',
      const SymbolLayerProperties(
        iconImage: 'photo-point',
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      filter: [
        '==',
        ['geometry-type'],
        'Point',
      ],
      enableInteraction: true,
    );
    _photoPointLayerReady = true;
  }

  /// Record pins. The sources are created empty and then kept in step with
  /// the database by the layer watch.
  Future<void> _addRecordLayers(MapLibreMapController controller) async {
    for (final s in const ['flagged', 'removed']) {
      await controller.addImage('obs-removal-$s', await removalMarker(s));
    }
    await controller.addGeoJsonSource('observations', _emptyCollection);
    await controller.addCircleLayer(
      'observations',
      'observations-circles',
      CircleLayerProperties(
        // Plants keep the fine dot; everything else (infrastructure, water,
        // problems…) draws larger — the non-plant inks are dark and a 7.5px
        // dot in near-black disappears against imagery (Austin, 2026-09-02).
        circleRadius: [
          'match',
          ['get', 'kind'],
          [
            'tree',
            'shrub',
            'graminoid',
            'forb',
            'vine',
            'succulent',
            'fern',
            'moss',
            'plant',
          ],
          7.5,
          9.5,
        ],
        // A named plant is coloured by what kind of plant it is — trees,
        // shrubs, grasses and forbs read apart at a glance. Everything else
        // falls back to the kind of record it is.
        circleColor: kindColorMatch(),
        circleStrokeColor: '#ECE3CE',
        circleStrokeWidth: 1.5,
      ),
      // The shaped kinds draw in the symbol layer below instead.
      filter: [
        '!',
        [
          'in',
          ['get', 'kind'],
          [
            'literal',
            ['infrastructure', 'maintenance', 'problem'],
          ],
        ],
      ],
      enableInteraction: true,
    );
    // Shaped records: squares for built things, a triangle for problems.
    await controller.addSymbolLayer(
      'observations',
      'observations-shapes',
      const SymbolLayerProperties(
        iconImage: [
          'match',
          ['get', 'kind'],
          'infrastructure',
          'obs-square-ink',
          'maintenance',
          'obs-square-ochre',
          'obs-triangle',
        ],
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      filter: [
        'in',
        ['get', 'kind'],
        [
          'literal',
          ['infrastructure', 'maintenance', 'problem'],
        ],
      ],
      enableInteraction: true,
    );
    // Removal (D-027) draws OVER the record's own mark: the ring and cut
    // say "this comes out", the dot beneath still says what it is.
    await controller.addSymbolLayer(
      'observations',
      'observations-removal',
      const SymbolLayerProperties(
        iconImage: [
          'match',
          ['get', 'removal'],
          'flagged',
          'obs-removal-flagged',
          'obs-removal-removed',
        ],
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      filter: [
        '!=',
        ['get', 'removal'],
        '',
      ],
      enableInteraction: true,
    );
    // Clusters: one badge with the count (image, so no glyphs needed).
    await controller.addGeoJsonSource('obs-clusters', _emptyCollection);
    await controller.addSymbolLayer(
      'obs-clusters',
      'obs-clusters-lyr',
      const SymbolLayerProperties(
        iconImage: ['get', 'icon'],
        iconSize: 1 / 3, // badges are drawn at 3× for crisp text
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      enableInteraction: true,
    );
    _recordLayersReady = true;
  }
}
