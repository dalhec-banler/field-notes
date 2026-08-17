import 'package:drift/drift.dart';

import '../db/database.dart';

/// Survival is always derived, never stored (spec §4.8).
///
/// Preference order:
/// 1. Tagged individuals exist → alive individuals / total individuals.
/// 2. Otherwise → most recent cohort-level check-in's count_alive over
///    count_planted.
/// 3. No signal yet → null (unknown, not 100%).
class SurvivalResult {
  const SurvivalResult({
    required this.alive,
    required this.total,
    required this.source,
  });

  final int alive;
  final int total;
  final String source; // 'individuals' | 'cohort_checkin'

  double get rate => total == 0 ? 0 : alive / total;
}

Future<SurvivalResult?> survivalFor(
  FieldNotesDb db,
  PlantingEvent event,
) async {
  final individuals = await (db.select(db.plants)
        ..where((p) => p.plantingEventId.equals(event.id))
        ..where((p) => p.deletedAt.isNull()))
      .get();
  if (individuals.isNotEmpty) {
    const aliveStatuses = {'alive', 'dormant', 'browsed', 'declining'};
    final alive = individuals
        .where((p) => aliveStatuses.contains(p.currentStatus))
        .length;
    return SurvivalResult(
      alive: alive,
      total: individuals.length,
      source: 'individuals',
    );
  }

  final checkin = await (db.select(db.plantCheckins)
        ..where((c) => c.plantingEventId.equals(event.id))
        ..where((c) => c.deletedAt.isNull())
        ..where((c) => c.countAlive.isNotNull())
        ..orderBy([(c) => OrderingTerm.desc(c.checkedAt)])
        ..limit(1))
      .getSingleOrNull();
  if (checkin != null && checkin.countAlive != null) {
    return SurvivalResult(
      alive: checkin.countAlive!,
      total: event.countPlanted,
      source: 'cohort_checkin',
    );
  }
  return null;
}
