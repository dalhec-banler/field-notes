import 'package:drift/drift.dart';

import '../db/database.dart';

/// Tag codes are free text; the UI suggests the next code in the user's
/// last-used pattern (DECISIONS.md D-005). 'SFS-BW-040' → 'SFS-BW-041',
/// preserving zero padding.
String? nextTagCode(String? lastCode) {
  if (lastCode == null || lastCode.isEmpty) return null;
  final match = RegExp(r'^(.*?)(\d+)$').firstMatch(lastCode.trim());
  if (match == null) return null;
  final prefix = match.group(1)!;
  final digits = match.group(2)!;
  final next = (int.parse(digits) + 1).toString().padLeft(digits.length, '0');
  return '$prefix$next';
}

/// Latest tag code used on the property (by creation order — UUIDv7 sorts by
/// time), for seeding the suggestion.
Future<String?> lastTagCode(FieldNotesDb db, String propertyId) async {
  final row =
      await (db.select(db.plants)
            ..where((p) => p.propertyId.equals(propertyId))
            ..where((p) => p.tagCode.isNotNull())
            ..where((p) => p.deletedAt.isNull())
            ..orderBy([(p) => OrderingTerm.desc(p.id)])
            ..limit(1))
          .getSingleOrNull();
  return row?.tagCode;
}
