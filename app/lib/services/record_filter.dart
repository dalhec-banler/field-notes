import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../repo/observations_repo.dart' show LedgerQuery;

/// ONE filter for the record surfaces (Austin, 2026-09-04: "seems like
/// the ledger should be the filter").
///
/// The Ledger's chips write it; the Ledger's list AND the map's record
/// layer read it — the map always shows exactly what the ledger shows,
/// and CLEAR clears both. A species jump ("show me every pecan") sets
/// the species here and asks the map to frame the result.
///
/// Process-wide, like the skin and the location hub: one filter, one
/// truth, per running app.
class RecordFilter extends ChangeNotifier {
  String? zoneId;
  String? zoneLabel;
  String? type;
  String? taxonId;
  String? taxonLabel;
  DateTimeRange? dates;

  /// Only records flagged for removal (D-027) — the contractor's view.
  bool flagged = false;

  bool _jump = false;

  bool get active =>
      zoneId != null ||
      type != null ||
      taxonId != null ||
      dates != null ||
      flagged;

  /// The banner's words: what the surfaces are narrowed to.
  String describe() => [
    if (flagged) 'flagged for removal',
    ?taxonLabel,
    ?type,
    ?zoneLabel,
    if (dates != null) '${_d(dates!.start)} – ${_d(dates!.end)}',
  ].join(' · ');

  static String _d(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The date range as half-open UTC ISO bounds on `observed_at`, or null
  /// when no dates are set. `observed_at` is ISO-8601 UTC; the chips pick
  /// local days, so local midnight → UTC. The end is day + 1 (not +24 h):
  /// Dart normalizes the overflow and keeps local midnight across a DST
  /// change.
  (String from, String to)? get utcDayBounds {
    final range = dates;
    if (range == null) return null;
    final from = DateTime(
      range.start.year,
      range.start.month,
      range.start.day,
    ).toUtc().toIso8601String();
    final to = DateTime(
      range.end.year,
      range.end.month,
      range.end.day + 1,
    ).toUtc().toIso8601String();
    return (from, to);
  }

  /// What the ledger asks the repo for: this filter, as plain data.
  LedgerQuery get query {
    final bounds = utcDayBounds;
    return LedgerQuery(
      zoneId: zoneId,
      type: type,
      taxonId: taxonId,
      flagged: flagged,
      fromUtc: bounds?.$1,
      toUtc: bounds?.$2,
    );
  }

  /// Mutate-and-notify in one move.
  void update(void Function(RecordFilter f) fn) {
    fn(this);
    notifyListeners();
  }

  void clear() {
    zoneId = null;
    zoneLabel = null;
    type = null;
    taxonId = null;
    taxonLabel = null;
    dates = null;
    flagged = false;
    notifyListeners();
  }

  /// Ask the map to come to the front and frame the filtered records.
  void jumpToMap() {
    _jump = true;
    notifyListeners();
  }

  /// The map (and the shell, for the tab switch) each consume this once.
  bool consumeJump() {
    final j = _jump;
    _jump = false;
    return j;
  }

  /// The shell peeks without consuming so both listeners can react.
  bool get jumpPending => _jump;
}

/// The filter the process started with — what the scope carries when
/// `main()` builds it, and what resolves before any scope is installed.
final _processFilter = RecordFilter();

/// The one filter this app runs on. LEGACY: a delegate to
/// `AppScope.current.recordFilter`; new code reads
/// `AppScope.of(context).recordFilter` (D-038 item 6).
RecordFilter get recordFilter =>
    AppScope.maybeCurrent?.recordFilter ?? _processFilter;
