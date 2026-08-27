import 'package:drift/drift.dart';

import '../db/database.dart';

/// Survival is always derived, never stored (spec §4.8).
///
/// Preference order:
/// 1. Tagged individuals exist → alive individuals / tagged individuals.
///    Spec §4.8 reads "alive plants over count_planted", but a cohort is
///    usually only partly tagged (3 tags on 40 cuttings), and 3/40 would read
///    as 8 % survival when every tagged plant is alive. The rate is therefore
///    over the tagged set and the UI labels it as such ("3 of 3 tagged
///    alive") so it is never mistaken for the cohort figure.
/// 2. Otherwise → most recent cohort-level check-in's count_alive over
///    count_planted (the spec's cohort figure: "31 of 40 alive · 78%").
/// 3. No signal yet → null (unknown, not 100%).
class SurvivalResult {
  const SurvivalResult({
    required this.alive,
    required this.total,
    required this.source,
    required this.countPlanted,
  });

  final int alive;

  /// Denominator: tagged individuals for [fromTags], else `count_planted`.
  final int total;
  final String source; // 'individuals' | 'cohort_checkin'

  /// The cohort size, for context when [fromTags].
  final int countPlanted;

  double get rate => total == 0 ? 0 : alive / total;

  bool get fromTags => source == 'individuals';

  /// Plain-language line for the UI. Cohort: "31 of 40 alive · 78%".
  /// Tags: "3 of 3 tagged alive" — no percent, it is not the cohort rate.
  String get summary => fromTags
      ? '$alive of $total tagged alive'
      : '$alive of $total alive · ${(rate * 100).toStringAsFixed(0)}%';
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
      countPlanted: event.countPlanted,
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
      countPlanted: event.countPlanted,
    );
  }
  return null;
}
