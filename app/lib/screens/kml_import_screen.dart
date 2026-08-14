import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:turf/turf.dart' as turf;

import '../db/database.dart';
import '../import/kml_import.dart';

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

  Future<void> _pick() async {
    setState(() => _error = null);
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'KML/KMZ', extensions: ['kml', 'kmz']),
    ]);
    if (file == null) return;
    try {
      final placemarks = file.name.toLowerCase().endsWith('.kmz')
          ? parseKmz(await file.readAsBytes())
          : parseKml(await file.readAsString());
      if (placemarks.isEmpty) {
        setState(() => _error = 'No placemarks found in ${file.name}');
        return;
      }
      setState(() {
        _rows = [
          for (final pm in placemarks) _Row(pm, _suggest(pm)),
        ];
      });
    } catch (e) {
      setState(() => _error = 'Could not read ${file.name}: $e');
    }
  }

  /// Geometry + folder-name heuristics; the user confirms every row.
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
      final existing = await (db.select(db.featureTypes)
            ..where((t) => t.typeKey.equals('imported'))
            ..limit(1))
          .getSingleOrNull();
      if (existing != null) return existing.id;
      final id = newId();
      await db.into(db.featureTypes).insert(FeatureTypesCompanion.insert(
            id: id,
            typeKey: 'imported',
            label: 'Imported',
            featureClass: 'natural',
            createdAt: now,
          ));
      return id;
    }

    for (final row in rows) {
      final pm = row.placemark;
      switch (row.destination) {
        case _Destination.skip:
          break;
        case _Destination.boundary:
          final centroid = _centroidOf(pm.geojson);
          await (db.update(db.properties)
                ..where((p) => p.id.equals(widget.property.id)))
              .write(PropertiesCompanion(
            boundaryGeojson: Value(pm.geojson),
            centroidLat: Value(centroid?.lat.toDouble()),
            centroidLng: Value(centroid?.lng.toDouble()),
            updatedAt: Value(now),
          ));
          boundarySet = pm.name;
        case _Destination.zone:
          await db.into(db.zones).insert(ZonesCompanion.insert(
                id: newId(),
                propertyId: widget.property.id,
                name: pm.name,
                geojson: pm.geojson,
                notes: Value(pm.description),
                createdBy: 'local',
                createdAt: now,
                updatedAt: now,
              ));
          zones++;
        case _Destination.feature:
          final centroid = _centroidOf(pm.geojson);
          await db.into(db.features).insert(FeaturesCompanion.insert(
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
              ));
          features++;
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text([
        if (boundarySet != null) 'Boundary set from "$boundarySet"',
        if (zones > 0) '$zones zone${zones == 1 ? '' : 's'}',
        if (features > 0) '$features feature${features == 1 ? '' : 's'}',
      ].join(' · ')),
    ));
  }

  turf.Position? _centroidOf(String geojson) {
    try {
      final g = turf.GeometryObject.deserialize(
          jsonDecode(geojson) as Map<String, dynamic>);
      final c = turf.centroid(turf.Feature(geometry: g as turf.GeometryType));
      return c.geometry?.coordinates;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('Import KML/KMZ')),
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
                      onPressed: _pick,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Choose file'),
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
                        subtitle: Text([
                          row.placemark.geometryType,
                          if (row.placemark.folder != null)
                            row.placemark.folder!,
                        ].join(' · ')),
                        trailing: DropdownButton<_Destination>(
                          value: row.destination,
                          onChanged: (d) => setState(
                              () => row.destination = d ?? _Destination.skip),
                          items: const [
                            DropdownMenuItem(
                                value: _Destination.boundary,
                                child: Text('Boundary')),
                            DropdownMenuItem(
                                value: _Destination.zone, child: Text('Zone')),
                            DropdownMenuItem(
                                value: _Destination.feature,
                                child: Text('Feature')),
                            DropdownMenuItem(
                                value: _Destination.skip, child: Text('Skip')),
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
