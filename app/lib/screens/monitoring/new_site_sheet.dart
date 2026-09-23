import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../../db/database.dart';
import '../../main.dart' show locationHub;
import '../../protocols/protocol_service.dart';
import '../../protocols/templates.dart';
import '../../services/compass.dart';
import '../../theme/tokens.dart';
import '../../widgets/press.dart';
import '../move_pin_screen.dart';

/// Put the first stake on the map.
///
/// Where you stand is the default origin (the phone's fresh fix); MOVE
/// THE PIN opens the imagery crosshair for anywhere else. A line takes a
/// bearing — the phone's heading, or a number — and a length; a plot a
/// radius. Nothing waits on GPS: with no fix, the map does the placing.
Future<ProtocolSite?> showNewSiteSheet(
  BuildContext context, {
  required FieldNotesDb db,
  required Property property,
  required Protocol protocol,
}) {
  return showModalBottomSheet<ProtocolSite>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _NewSiteSheet(db: db, property: property, protocol: protocol),
  );
}

class _NewSiteSheet extends StatefulWidget {
  const _NewSiteSheet({
    required this.db,
    required this.property,
    required this.protocol,
  });

  final FieldNotesDb db;
  final Property property;
  final Protocol protocol;

  @override
  State<_NewSiteSheet> createState() => _NewSiteSheetState();
}

class _NewSiteSheetState extends State<_NewSiteSheet> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.protocol.name} 1',
  );
  late final TextEditingController _bearing = TextEditingController();
  late final TextEditingController _length = TextEditingController(
    text: _template?.defaultLengthM?.toStringAsFixed(0) ?? '',
  );
  late final TextEditingController _radius = TextEditingController(
    text: _template?.defaultRadiusM?.toString() ?? '',
  );
  double? _lat;
  double? _lng;
  double? _accuracy;
  String _marker = 'none';
  bool _alsoPhotoPoint = false;
  bool _saving = false;
  CompassStream? _compass;

  ProtocolTemplate? get _template => templateFor(widget.protocol.methodKey);
  String get _kind => widget.protocol.siteKind;

  @override
  void initState() {
    super.initState();
    _seedFromFix();
    _countSites();
  }

  @override
  void dispose() {
    _name.dispose();
    _bearing.dispose();
    _length.dispose();
    _radius.dispose();
    _compass?.dispose();
    super.dispose();
  }

  Future<void> _countSites() async {
    final n = (await ProtocolService(widget.db).sitesFor(
      widget.property.id,
      includeRetired: true,
    )).where((s) => s.protocolId == widget.protocol.id).length;
    if (mounted) _name.text = '${widget.protocol.name} ${n + 1}';
  }

  void _seedFromFix() {
    final fix = locationHub.fresh();
    if (fix != null) {
      _lat = fix.latitude;
      _lng = fix.longitude;
      _accuracy = fix.accuracy;
    } else {
      // A cached fix is a fair start for the map even if it is stale.
      Geolocator.getLastKnownPosition()
          .then((p) {
            if (p == null || !mounted || _lat != null) return;
            setState(() {
              _lat = p.latitude;
              _lng = p.longitude;
              _accuracy = null;
            });
          })
          .catchError((_) {});
    }
  }

  Future<void> _movePin() async {
    final start = LatLng(
      _lat ?? widget.property.centroidLat ?? 39.5,
      _lng ?? widget.property.centroidLng ?? -98.35,
    );
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) =>
            MovePinScreen(lat: start.latitude, lng: start.longitude),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _lat = picked.latitude;
      _lng = picked.longitude;
      _accuracy = null; // hand-placed
    });
  }

  void _useHeading() {
    _compass ??= CompassStream();
    _compass!.headingDeg.first.then((h) {
      if (mounted) setState(() => _bearing.text = h.round().toString());
    });
  }

  Future<void> _save() async {
    final lat = _lat;
    final lng = _lng;
    if (lat == null || lng == null || _saving) return;
    setState(() => _saving = true);
    final svc = ProtocolService(widget.db);
    String? photoPointId;
    final bearing = double.tryParse(_bearing.text.trim());
    if (_alsoPhotoPoint) {
      final now = nowUtcIso();
      photoPointId = newId();
      await widget.db
          .into(widget.db.photoPoints)
          .insert(
            PhotoPointsCompanion.insert(
              id: photoPointId,
              propertyId: widget.property.id,
              name: _name.text.trim(),
              lat: lat,
              lng: lng,
              bearingDeg: bearing ?? 0,
              subject: Value('${widget.protocol.name} stake'),
              cadenceDays: Value(widget.protocol.cadenceDays),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    final site = await svc.createSite(
      protocol: widget.protocol,
      name: _name.text.trim().isEmpty
          ? widget.protocol.name
          : _name.text.trim(),
      lat: lat,
      lng: lng,
      gpsAccuracyM: _accuracy,
      bearingDeg: bearing,
      lengthM: double.tryParse(_length.text.trim()),
      radiusM: double.tryParse(_radius.text.trim()),
      marker: _marker,
      photoPointId: photoPointId,
    );
    if (mounted) Navigator.of(context).pop(site);
  }

  @override
  Widget build(BuildContext context) {
    final placed = _lat != null && _lng != null;
    final where = !placed
        ? 'No position yet — MOVE THE PIN to place it on the imagery.'
        : _accuracy == null
        ? 'Placed by hand at ${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}'
        : 'Where you stand · ±${_accuracy!.round()} m';
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(
          Metrics.gutter,
          18,
          Metrics.gutter,
          24,
        ),
        children: [
          Kicker('New site · ${widget.protocol.name}'),
          const SizedBox(height: 4),
          Text(
            'The stake goes in once. Every visit comes back to it.',
            style: TextStyle(fontFamily: Type.serif, fontSize: 14.5),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'NAME'),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 14),
          MonoLabel(where, size: 9.5, opacity: 0.8),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('WHERE I STAND'),
                    onPressed: () {
                      final fix = locationHub.fresh();
                      if (fix == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('No fresh GPS fix yet.'),
                          ),
                        );
                        return;
                      }
                      setState(() {
                        _lat = fix.latitude;
                        _lng = fix.longitude;
                        _accuracy = fix.accuracy;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    icon: const Icon(
                      Icons.edit_location_alt_outlined,
                      size: 18,
                    ),
                    label: const Text('MOVE THE PIN'),
                    onPressed: _movePin,
                  ),
                ),
              ),
            ],
          ),
          if (_kind == 'line' || _kind == 'route') ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _bearing,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'BEARING °',
                      hintText: 'which way the tape runs',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: _useHeading,
                    child: const Text('MY HEADING'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _length,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'LENGTH · m'),
            ),
          ],
          if (_kind == 'plot') ...[
            const SizedBox(height: 14),
            TextField(
              controller: _radius,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'RADIUS · m',
                hintText: '3.59 m is a hundredth of an acre',
              ),
            ),
          ],
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _marker,
            decoration: const InputDecoration(
              labelText: 'WHAT IS IN THE GROUND',
            ),
            items: const [
              DropdownMenuItem(value: 'none', child: Text('Nothing yet')),
              DropdownMenuItem(value: 'rebar', child: Text('Rebar')),
              DropdownMenuItem(value: 't_post', child: Text('T-post')),
              DropdownMenuItem(value: 'flag', child: Text('Flag')),
              DropdownMenuItem(value: 'cairn', child: Text('Rock cairn')),
            ],
            onChanged: (v) => setState(() => _marker = v ?? 'none'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Also a photo point'),
            subtitle: const Text(
              'The stake is where the camera stands. Same spot, same '
              'direction, for years.',
            ),
            value: _alsoPhotoPoint,
            onChanged: (v) => setState(() => _alsoPhotoPoint = v),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 56,
            child: FilledButton(
              onPressed: placed && !_saving ? _save : null,
              child: Text(_saving ? 'SAVING…' : 'PUT THE STAKE IN'),
            ),
          ),
        ],
      ),
    );
  }
}
