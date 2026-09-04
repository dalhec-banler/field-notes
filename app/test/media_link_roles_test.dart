import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/media_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression: a voice note was linked with `role: 'voice'`, which the
/// schema's CHECK rejects. The insert threw inside the capture transaction,
/// so the whole record — photo, notes, recording — was rolled back and the
/// files erased. Every role the app writes must be one the schema accepts.
void main() {
  late FieldNotesDb db;
  late String propId;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    final now = nowUtcIso();
    propId = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Yard',
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() => db.close());

  Future<void> link(String role) async {
    final now = nowUtcIso();
    final mediaId = newId();
    await db
        .into(db.media)
        .insert(
          MediaCompanion.insert(
            id: mediaId,
            propertyId: propId,
            mediaType: 'audio',
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await MediaStore(db).linkTo(
      mediaId,
      propertyId: propId,
      entityType: 'observation',
      entityId: newId(),
      role: role,
    );
  }

  test('every role the app writes is accepted by the schema', () async {
    // capture: photo 'primary', voice note 'attachment';
    // ghost capture: 'reference' on the first visit, else 'attachment'.
    for (final role in const [
      'primary',
      'attachment',
      'reference',
      'before',
      'after',
    ]) {
      await link(role);
    }
    expect(await db.select(db.mediaLinks).get(), hasLength(5));
  });

  test('an unknown role is rejected, not silently stored', () async {
    await expectLater(link('voice'), throwsA(isA<Exception>()));
  });
}
