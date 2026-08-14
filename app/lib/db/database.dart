import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

export 'ids.dart';

part 'database.g.dart';

@DriftDatabase(include: {'schema.drift'})
class FieldNotesDb extends _$FieldNotesDb {
  FieldNotesDb() : super(_openConnection());

  /// In-memory database for tests.
  FieldNotesDb.forTesting() : super(NativeDatabase.memory());

  /// Opens an existing database file (restore/verification flows).
  FieldNotesDb.fromFile(File file) : super(NativeDatabase(file));

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async => m.createAll(),
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'field_notes.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

/// ISO-8601 UTC timestamp per spec §4.1.
String nowUtcIso() => DateTime.now().toUtc().toIso8601String();

/// Wall-clock timezone name for the `local_tz` columns.
String localTzName() => DateTime.now().timeZoneName;
