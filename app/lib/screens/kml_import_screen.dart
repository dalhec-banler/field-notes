import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:turf/turf.dart' as turf;

import '../db/database.dart';
import '../widgets/press.dart';
import '../import/kml_import.dart';
import '../services/property_locator.dart';

/// KML/KMZ import review step (spec §6): nothing commits until the user has
/// assigned each placemark a destination.
class KmlImportScreen extends StatefulWidget {
  const KmlImportScreen({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<KmlImportScreen> createState() => _KmlImportScreenState();
}

enum _Destination { boundary, zone, feature, skip }

class _Row {
  _Row(this.placemark, this.destination);
  final KmlPlacemark placemark;
  _Destination destination;
}

class _KmlImportScreenState extends State<KmlImportScreen> {
  List<_Row>? _rows;
  String? _error;
  bool _committing = false;
  bool _fetching = false;
  String? _sourceName;
  String _sourceKind = 'file';
  final _linkCtl = TextEditingController();

  Future<void> _pick() async {
    setState(() => _error = null);
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'KML / KMZ / GeoJSON / GPX',
          extensions: ['kml', 'kmz', 'geojson', 'json', 'gpx'],
        ),
      ],
    );
    if (file == null) return;
    try {
      final lower = file.name.toLowerCase();
      final placemarks = lower.endsWith('.kmz')
          ? parseKmz(await file.readAsBytes())
          : lower.endsWith('.geojson') || lower.endsWith('.json')
          ? parseGeoJson(await file.readAsString())
          : lower.endsWith('.gpx')
          ? parseGpx(await file.readAsString())
          : parseKml(await file.readAsString());
      if (!mounted) return;
      if (placemarks.isEmpty) {
        setState(() => _error = 'No placemarks found in ${file.name}');
        return;
      }
      setState(() {
        _sourceName = file.name;
        _sourceKind = 'file';
        _rows = [for (final pm in placemarks) _Row(pm, _suggest(pm))];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not read ${file.name}: $e');
    }
  }

  /// Geometry + folder-name heuristics; the user confirms every row.
  /// Pull a map straight off a Google Earth / My Maps share link. Both serve
  /// the document as KML or KMZ when asked plainly; no account, no scopes.
  Future<void> _pickLink(String raw) async {
    final url = _kmlUrlFor(raw.trim());
    if (url == null) {
      setState(() => _error = _whyNotFetchable(raw.trim()));
      return;
    }
    setState(() { _error = null; _fetching = true; });
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw Exception('the server answered ${res.statusCode} — is the map shared by link?');
      }
      final body = res.bodyBytes;
      final isZip = body.length > 1 && body[0] == 0x50 && body[1] == 0x4B; // 'PK'
      if (!isZip) {
        final head = utf8
            .decode(body.take(400).toList(), allowMalformed: true)
            .trimLeft()
            .toLowerCase();
        if (head.startsWith('<!doctype html') || head.startsWith('<html')) {
          throw Exception(
              'that link served a web page, not a map file — it probably needs '
              'a sign-in, or the map is not shared by link');
        }
      }
      final placemarks = isZip ? parseKmz(body) : parseKml(utf8.decode(body));
      if (!mounted) return;
      if (placemarks.isEmpty) {
        setState(() => _error = 'No placemarks in that map.');
        return;
      }
      setState(() {
        _sourceName = raw.trim();
        _sourceKind = 'link';
        _rows = [for (final pm in placemarks) _Row(pm, _suggest(pm))];
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not fetch that map: $e');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  /// My Maps hands out KML to anyone with the link — the map id rides in
  /// `mid`. Earth web projects do not: they live in the owner's Drive and the
  /// share link opens the Earth app, so there is nothing to fetch without
  /// authenticating. Those get told to export the file instead of being
  /// fetched and failing on a page of HTML.
  String? _kmlUrlFor(String link) {
    if (link.isEmpty) return null;
    final u = Uri.tryParse(link);
    if (u == null || !u.hasScheme) return null;
    final mid = u.queryParameters['mid'];
    if (mid != null && mid.isNotEmpty) {
      return 'https://www.google.com/maps/d/kml?forcekml=1&mid=$mid';
    }
    final low = link.toLowerCase();
    if (low.endsWith('.kml') || low.endsWith('.kmz')) return link;
    return null;
  }

  /// Why a link can't be fetched, said plainly.
  String _whyNotFetchable(String link) {
    final low = link.toLowerCase();
    if (low.contains('earth.google.com')) {
      return 'Google Earth projects can\'t be fetched by link — they live in '
          'your Drive and the link just opens Earth. In Earth, open the '
          'project menu and choose "Export as KML file", then use Choose file '
          'above. A My Maps link works here, or any direct .kml/.kmz URL.';
    }
    if (low.contains('drive.google.com')) {
      return 'A Drive link points at a viewer page, not the file itself. '
          'Download the .kml or .kmz and use Choose file above.';
    }
    return 'That link doesn\'t point at a map file. Use a My Maps share link, '
        'a direct .kml or .kmz URL, or Choose file above.';
  }

  _Destination _suggest(KmlPlacemark pm) {
    final name = '${pm.folder ?? ''}/${pm.name}'.toLowerCase();
    final isArea =
        pm.geometryType == 'Polygon' || pm.geometryType == 'MultiPolygon';
    if (isArea && name.contains('boundar')) return _Destination.boundary;
    if (isArea) return _Destination.zone;
    return _Destination.feature;
  }

  Future<void> _commit() async {
    final rows = _rows;
    if (rows == null || _committing) return;
    setState(() => _committing = true);
    final db = widget.db;
    final now = nowUtcIso();
    var zones = 0, features = 0;
    String? boundarySet;

    // Imported features need a type; use/create a generic one per property.
    Future<String> importedTypeId() async {
      final existing =
          await (db.select(db.featureTypes)
                ..where((t) => t.typeKey.equals('imported'))
                ..limit(1))
              .getSingleOrNull();
      if (existing != null) return existing.id;
      final id = newId();
      await db
          .into(db.featureTypes)
          .insert(
            FeatureTypesCompanion.insert(
              id: id,
              typeKey: 'imported',
              label: 'Imported',
              featureClass: 'natural',
              createdAt: now,
            ),
          );
      return id;
    }

    // Per row, not all-or-nothing. A file with one bad placemark used to
    // take every good one down with it (nine polygons lost to two stray
    // points). Each row now succeeds or fails on its own and the summary
    // says which.
    final failures = <String>[];
    var updated = 0;
    // One register row per import, so this whole map can be removed again.
    final importId = newId();
    await db.into(db.mapImports).insert(MapImportsCompanion.insert(
          id: importId,
          propertyId: widget.property.id,
          sourceName: _sourceName ?? 'imported map',
          sourceKind: _sourceKind,
          importedAt: now,
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
    for (final row in rows) {
      final pm = row.placemark;
      try {
        switch (row.destination) {
          case _Destination.skip:
            break;
          case _Destination.boundary:
            final centroid = _centroidOf(pm.geojson);
            await (db.update(
              db.properties,
            )..where((p) => p.id.equals(widget.property.id))).write(
              PropertiesCompanion(
                boundaryGeojson: Value(pm.geojson),
                centroidLat: Value(centroid?.lat.toDouble()),
                centroidLng: Value(centroid?.lng.toDouble()),
                updatedAt: Value(now),
              ),
            );
            boundarySet = pm.name;
            if (centroid != null) {
              await PropertyLocator(db).noteLocation(
                widget.property.id,
                centroid.lat.toDouble(),
                centroid.lng.toDouble(),
                setCentroid: false,
              );
            }
          case _Destination.zone:
            // Match on name so a redraw updates the zone in place instead of
            // stacking a duplicate beside it. Whatever the zone already
            // carries — its code, its type — survives the redraw.
            final existing = await (db.select(db.zones)
                  ..where((z) =>
                      z.propertyId.equals(widget.property.id) &
                      z.name.equals(pm.name) &
                      z.deletedAt.isNull())
                  ..limit(1))
                .getSingleOrNull();
            final acres = _acresOf(pm.geojson);
            if (existing != null) {
              await (db.update(db.zones)..where((z) => z.id.equals(existing.id)))
                  .write(ZonesCompanion(
                geojson: Value(pm.geojson),
                areaAcres: Value(acres),
                colorHex: pm.colorHex != null
                    ? Value(pm.colorHex)
                    : const Value.absent(),
                zoneType: existing.zoneType == null
                    ? Value(_zoneTypeFor(pm.name))
                    : const Value.absent(),
                notes: Value(pm.description ?? existing.notes),
                importId: Value(importId),
                updatedAt: Value(now),
              ));
              updated++;
            } else {
              await db.into(db.zones).insert(
                    ZonesCompanion.insert(
                      id: newId(),
                      propertyId: widget.property.id,
                      name: pm.name,
                      geojson: pm.geojson,
                      areaAcres: Value(acres),
                      colorHex: Value(pm.colorHex),
                      zoneType: Value(_zoneTypeFor(pm.name)),
                      notes: Value(pm.description),
                      importId: Value(importId),
                      createdBy: 'local',
                      createdAt: now,
                      updatedAt: now,
                    ),
                  );
              zones++;
            }
          case _Destination.feature:
            final centroid = _centroidOf(pm.geojson);
            await db.into(db.features).insert(
                  FeaturesCompanion.insert(
                    id: newId(),
                    propertyId: widget.property.id,
                    featureTypeId: await importedTypeId(),
                    name: Value(pm.name),
                    geojson: pm.geojson,
                    lat: Value(centroid?.lat.toDouble()),
                    lng: Value(centroid?.lng.toDouble()),
                    notes: Value(pm.description),
                    createdBy: 'local',
                    createdAt: now,
                    updatedAt: now,
                  ),
                );
            features++;
        }
      } catch (e) {
        failures.add('${pm.name}: $e');
      }
    }
    if (zones + updated + features == 0) {
      await (db.delete(db.mapImports)..where((t) => t.id.equals(importId))).go();
    } else {
      await (db.update(db.mapImports)..where((t) => t.id.equals(importId)))
          .write(MapImportsCompanion(
        zoneCount: Value(zones + updated),
        featureCount: Value(features),
        updatedAt: Value(now),
      ));
    }
    if (mounted) setState(() => _committing = false);
    if (failures.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(failures.length == 1
            ? 'One placemark did not import — ${failures.first}'
            : '${failures.length} placemarks did not import — ${failures.first}'),
      ));
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          [
            if (boundarySet != null) 'Boundary set from "$boundarySet"',
            if (zones > 0) '$zones zone${zones == 1 ? '' : 's'}',
            if (updated > 0) '$updated updated in place',
            if (features > 0) '$features feature${features == 1 ? '' : 's'}',
            if (boundarySet == null && zones == 0 && features == 0)
              'Nothing selected to import',
          ].join(' · '),
        ),
      ),
    );
  }

  /// Acres from the stored ring, so a zone always reports the shape it has.
  double? _acresOf(String geojson) {
    try {
      final g = turf.GeometryObject.deserialize(
        jsonDecode(geojson) as Map<String, dynamic>,
      );
      final a = turf.area(turf.Feature(geometry: g as turf.GeometryType));
      return a == null ? null : a / 4046.8564224;
    } catch (_) {
      return null;
    }
  }

  /// A first guess at what kind of place this is, from what it was called.
  /// Only ever used to fill a blank — never to overwrite a type already set.
  String? _zoneTypeFor(String name) {
    final n = name.toLowerCase();
    bool has(List<String> w) => w.any(n.contains);
    if (has(['wetland', 'marsh', 'pocket', 'pond'])) return 'wet_depression';
    if (has(['river', 'riparian', 'creek', 'drainage', 'inflow', 'filter'])) {
      return 'riparian';
    }
    if (has(['shelterbelt', 'woodland', 'motte', 'savanna', 'timber'])) {
      return 'woodland';
    }
    if (has(['pasture', 'hay', 'field', 'agricultur', 'forage'])) return 'pasture';
    if (has(['prairie', 'grassland', 'meadow'])) return 'grassland';
    if (has(['upland', 'ridge', 'headwater'])) return 'upland';
    return null;
  }

  turf.Position? _centroidOf(String geojson) {
    try {
      final g = turf.GeometryObject.deserialize(
        jsonDecode(geojson) as Map<String, dynamic>,
      );
      final c = turf.centroid(turf.Feature(geometry: g as turf.GeometryType));
      return c.geometry?.coordinates;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _linkCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('Import boundary & zones')),
      body: rows == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                  SizedBox(
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _fetching ? null : _pick,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Choose file'),
                    ),
                  ),
                  const SizedBox(height: 26),
                  MonoLabel('OR PASTE A MAP LINK'),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: 460,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _linkCtl,
                            enabled: !_fetching,
                            decoration: const InputDecoration(
                              hintText: 'A My Maps share link, or a direct .kml / .kmz URL',
                              isDense: true,
                            ),
                            onSubmitted: _pickLink,
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          height: 44,
                          child: OutlinedButton(
                            onPressed:
                                _fetching ? null : () => _pickLink(_linkCtl.text),
                            child: Text(_fetching ? 'FETCHING…' : 'FETCH'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  const SizedBox(
                    width: 460,
                    child: Text(
                      'My Maps links only. Earth projects have to be exported as KML and opened above.',
                      style: TextStyle(fontSize: 12.5),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      return ListTile(
                        minTileHeight: 64,
                        leading: Icon(switch (row.placemark.geometryType) {
                          'Point' => Icons.place_outlined,
                          'LineString' => Icons.timeline,
                          _ => Icons.pentagon_outlined,
                        }),
                        title: Text(row.placemark.name),
                        subtitle: Text(
                          [
                            row.placemark.geometryType,
                            if (row.placemark.folder != null)
                              row.placemark.folder!,
                          ].join(' · '),
                        ),
                        trailing: DropdownButton<_Destination>(
                          value: row.destination,
                          onChanged: (d) => setState(
                            () => row.destination = d ?? _Destination.skip,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: _Destination.boundary,
                              child: Text('Boundary'),
                            ),
                            DropdownMenuItem(
                              value: _Destination.zone,
                              child: Text('Zone'),
                            ),
                            DropdownMenuItem(
                              value: _Destination.feature,
                              child: Text('Feature'),
                            ),
                            DropdownMenuItem(
                              value: _Destination.skip,
                              child: Text('Skip'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton.icon(
                        onPressed: _committing ? null : _commit,
                        icon: const Icon(Icons.check),
                        label: Text(_committing ? 'Importing…' : 'Import'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
