import 'package:flutter/material.dart';

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

/// The one filter this app runs on.
final recordFilter = RecordFilter();
