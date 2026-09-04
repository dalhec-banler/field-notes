import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../screens/features_screen.dart';
import '../theme/tokens.dart';
import 'confirm.dart';
import 'press.dart';

/// Tap a feature marker: what it is, its condition, and the way into the
/// Features screen to log a condition or edit it.
Future<void> showFeatureSheet(
  BuildContext context, {
  required FieldNotesDb db,
  required Property property,
  required String featureId,
}) async {
  final row = await db
      .customSelect(
        'SELECT f.name AS name, f.current_condition AS cond, f.notes AS notes, '
        'f.installed_on AS installed, t.label AS label, t.feature_class AS cls, '
        'z.name AS zone '
        'FROM features f JOIN feature_types t ON t.id = f.feature_type_id '
        'LEFT JOIN zones z ON z.id = f.zone_id WHERE f.id = ?',
        variables: [Variable.withString(featureId)],
      )
      .getSingleOrNull();
  if (row == null || !context.mounted) return;
  final name = (row.data['name'] as String?) ?? row.data['label'] as String;
  final cond = row.data['cond'] as String?;
  final condColor = conditionColor(cond);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Press.paper,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(Metrics.gutter, 14, Metrics.gutter, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Kicker('${row.data['label']} · ${row.data['cls']}'),
          SizedBox(height: 6),
          Text(
            name,
            style: TextStyle(
              fontFamily: Type.slab,
              fontWeight: FontWeight.w900,
              fontSize: 24,
              color: Press.ink,
            ),
          ),
          SizedBox(height: 10),
          Row(
            children: [
              if (cond != null)
                StatusPill(cond.toUpperCase(), color: condColor, filled: true),
              if (cond != null) SizedBox(width: 8),
              if (row.data['zone'] != null)
                MonoLabel(row.data['zone'] as String, size: 9, opacity: 0.7),
            ],
          ),
          if ((row.data['notes'] as String?)?.isNotEmpty ?? false) ...[
            SizedBox(height: 10),
            Text(
              row.data['notes'] as String,
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 15,
                height: 1.45,
              ),
            ),
          ],
          SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Metrics.touchMin,
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              FeaturesScreen(db: db, property: property),
                        ),
                      );
                    },
                    child: Text('OPEN FEATURES'),
                  ),
                ),
              ),
              SizedBox(width: 8),
              SizedBox(
                height: Metrics.touchMin,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Press.oxblood,
                  ),
                  onPressed: () async {
                    final sure = await confirmDialog(
                      ctx,
                      title: 'DELETE THIS FEATURE?',
                      body:
                          'It leaves the map and its condition history goes '
                          'quiet. Nothing is erased from disk.',
                      confirmLabel: 'DELETE',
                    );
                    if (!sure || !ctx.mounted) return;
                    final now = nowUtcIso();
                    await (db.update(
                      db.features,
                    )..where((f) => f.id.equals(featureId))).write(
                      FeaturesCompanion(
                        deletedAt: Value(now),
                        updatedAt: Value(now),
                      ),
                    );
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  child: Text('DELETE'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
