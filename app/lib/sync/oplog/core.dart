part of '../oplog.dart';

/// What every part of the log reaches for: the connection, this
/// installation's id and the conflict log. `OpLog` owns the fields;
/// the chain declares them here so the parts can be written against
/// them.
mixin _OpLogCore {
  FieldNotesDb get db;
  String get deviceId;
  ConflictLog get conflicts;
}
