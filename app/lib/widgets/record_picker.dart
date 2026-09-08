import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../theme/tokens.dart';
import 'press.dart';

/// One record chosen from a place's ledger — what a mother plant points
/// back at (D-029): the day you found it, and where.
class PickedRecord {
  const PickedRecord({
    required this.id,
    required this.lat,
    required this.lng,
    required this.label,
  });
  final String id;
  final double lat;
  final double lng;
  final String label;
}

/// Pick a located record on [propertyId], the species' own records first
/// when [taxonId] is known. Returns null when dismissed.
Future<PickedRecord?> showRecordPicker(
  BuildContext context, {
  required FieldNotesDb db,
  required String propertyId,
  String? taxonId,
}) async {
  final rows = await db
      .customSelect(
        'SELECT o.id AS id, o.observed_at AS at, o.lat AS lat, o.lng AS lng, '
        'o.observation_type AS type, o.notes AS notes, o.taxon_id AS taxon, '
        'COALESCE(t.common_name, t.scientific_name) AS species '
        'FROM observations o LEFT JOIN taxa t ON t.id = o.taxon_id '
        'WHERE o.property_id = ? AND o.deleted_at IS NULL '
        'AND (o.gps_accuracy_m IS NULL OR o.gps_accuracy_m != -1) '
        'ORDER BY CASE WHEN o.taxon_id = ? THEN 0 ELSE 1 END, '
        'o.observed_at DESC LIMIT 400',
        variables: [
          Variable.withString(propertyId),
          Variable.withString(taxonId ?? ''),
        ],
        readsFrom: {db.observations, db.taxa},
      )
      .get();
  if (!context.mounted) return null;
  return showModalBottomSheet<PickedRecord>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Press.paper,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(Metrics.gutter, 14, Metrics.gutter, 24),
        children: [
          MonoLabel('Which record is the mother plant?', size: 10, spacing: 2),
          const SizedBox(height: 6),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No located records on this place yet.',
                style: TextStyle(fontFamily: Type.serif, color: Press.inkSoft),
              ),
            ),
          for (final r in rows)
            ListTile(
              minTileHeight: 56,
              contentPadding: EdgeInsets.zero,
              leading: Diamond(
                size: 10,
                color: r.data['taxon'] == taxonId && taxonId != null
                    ? Press.oxblood
                    : Press.inkSoft,
              ),
              title: Text(
                (r.data['species'] as String?) ??
                    (r.data['type'] as String? ?? 'record').toUpperCase(),
                style: TextStyle(fontFamily: Type.serif, fontSize: 15),
              ),
              subtitle: MonoLabel(
                [
                  (r.data['at'] as String).substring(0, 10),
                  if (r.data['notes'] != null) r.data['notes'] as String,
                ].join(' · '),
                size: 9,
                opacity: 0.7,
              ),
              onTap: () => Navigator.pop(
                ctx,
                PickedRecord(
                  id: r.data['id'] as String,
                  lat: (r.data['lat'] as num).toDouble(),
                  lng: (r.data['lng'] as num).toDouble(),
                  label:
                      '${(r.data['species'] as String?) ?? r.data['type']} · '
                      '${(r.data['at'] as String).substring(0, 10)}',
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
