import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// UUIDv7 primary key per spec §4.1 — time-ordered, generated client-side.
String newId() => _uuid.v7();
