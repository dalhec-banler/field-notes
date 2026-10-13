import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/backup_crypto.dart';
import 'package:field_notes/backup/backup_engine.dart';
import 'package:field_notes/backup/keyring.dart';
import 'package:field_notes/backup/restore.dart';
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/capture_writer.dart';
import 'package:field_notes/services/observation_ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'smoke_store.dart';

/// The smoke suite: the app's real write paths against an isolated store,
/// with one invariant under test — a saved record is never lost or hidden.
/// Every case ends by counting observations, media and media_links.
///
/// Registered from two entry points: `test/smoke/smoke_test.dart` on the
/// host and `integration_test/smoke_test.dart` on a device. Services, not
/// widgets: writeCapture is what the capture screen calls, soft delete and
/// edit are what the record screen calls, UNDO is eraseObservation, and
/// backup/restore is BackupEngine + RestorePipeline as Settings drives
/// them.
/// Device runs include an Argon2 KDF and real JPEG work; roomy on purpose.
const smokeTimeout = Timeout(Duration(minutes: 4));

void registerSmokeCases() {
  group('smoke', () {
    late SmokeStore store;
    late Property property;
    late Directory scratch;

    setUp(() async {
      store = await SmokeStore.open();
      property = await (store.db.select(
        store.db.properties,
      )..where((x) => x.id.equals(store.propertyId))).getSingle();
      scratch = Directory(p.join(store.root.path, 'scratch'))..createSync();
    });

    tearDown(() => store.dispose());

    /// A live fix a few metres inside the store's zone.
    const fix = CaptureFix(
      lat: SmokeStore.lat + 0.0005,
      lng: SmokeStore.lng - 0.0004,
      accuracyM: 4.2,
      altitudeM: 312,
      headingDeg: 140,
    );

    Future<Observation> row(String id) => (store.db.select(
      store.db.observations,
    )..where((o) => o.id.equals(id))).getSingle();

    Future<List<MediaLink>> linksOf(String obsId) =>
        (store.db.select(store.db.mediaLinks)
              ..where((l) => l.entityId.equals(obsId))
              ..orderBy([(l) => OrderingTerm.asc(l.createdAt)]))
            .get();

    Future<List<MediaData>> mediaOf(String obsId) async {
      final links = await linksOf(obsId);
      return (store.db.select(store.db.media)
            ..where((m) => m.id.isIn([for (final l in links) l.mediaId])))
          .get();
    }

    test('(a) capture with a photo lands and survives a relaunch', () async {
      final before = await countsOf(store.db);
      final photo = writeFile(p.join(scratch.path, 'shot.jpg'), smallJpeg());

      final written = await writeCapture(
        store.db,
        CaptureDraft(
          observationId: newId(),
          property: property,
          photos: [photo],
          fix: fix,
          fixIsLive: true,
          observationType: 'plant',
          notes: 'Live oak resprout, knee high.',
        ),
      );

      var after = await countsOf(store.db);
      expect(after.observations, before.observations + 1);
      expect(after.live, before.live + 1);
      expect(after.media, before.media + 1);
      expect(after.mediaLinks, before.mediaLinks + 1);
      expect(after.envContexts, before.envContexts + 1);

      final obs = await row(written.observationId);
      expect(obs.deletedAt, isNull);
      expect(obs.gpsAccuracyM, fix.accuracyM, reason: 'live fix is recorded');
      expect(obs.zoneId, isNotNull, reason: 'the fix is inside the zone');
      expect(obs.envContextId, isNotNull);
      expect(obs.notes, 'Live oak resprout, knee high.');

      final link = (await linksOf(obs.id)).single;
      expect(link.role, 'primary');
      final media = (await mediaOf(obs.id)).single;
      expect(media.mediaType, 'photo');
      expect(media.sha256, isNotNull);
      expect(
        p.isWithin(p.join(store.root.path, 'media', 'photos'), media.localPath!),
        isTrue,
        reason: 'the photo is filed under the isolated store, nowhere else',
      );
      for (final f in filesFor(media)) {
        expect(f.existsSync(), isTrue, reason: '${f.path} on disk');
      }

      // A relaunch reads it all back from the file.
      await store.reopen();
      after = await countsOf(store.db);
      expect(after.observations, before.observations + 1);
      expect(after.media, before.media + 1);
      expect(after.mediaLinks, before.mediaLinks + 1);
      expect((await row(obs.id)).notes, obs.notes);
    }, timeout: smokeTimeout);

    test('(b) capture with a voice note keeps the audio and the link', () async {
      final before = await countsOf(store.db);
      final photo = writeFile(p.join(scratch.path, 'shot.jpg'), smallJpeg());
      final voice = fakeVoiceNote(scratch);

      final written = await writeCapture(
        store.db,
        CaptureDraft(
          observationId: newId(),
          property: property,
          photos: [photo],
          voice: voice,
          voiceDurationMs: 6200,
          voiceTranscript: 'two does and a fawn at the crossing',
          fix: fix,
          fixIsLive: true,
          observationType: 'wildlife',
          notes: 'two does and a fawn at the crossing',
        ),
      );

      final after = await countsOf(store.db);
      expect(after.observations, before.observations + 1);
      expect(after.media, before.media + 2, reason: 'photo + audio');
      expect(after.mediaLinks, before.mediaLinks + 2);
      expect(written.voiceMediaId, isNotNull);

      final links = await linksOf(written.observationId);
      final voiceLink = links.singleWhere(
        (l) => l.mediaId == written.voiceMediaId,
      );
      // The role that once failed the schema CHECK and rolled the whole
      // capture back (test/media_link_roles_test.dart). Audio is marked by
      // media_type, not by role.
      expect(voiceLink.role, 'attachment');
      final audio = (await mediaOf(
        written.observationId,
      )).singleWhere((m) => m.id == written.voiceMediaId);
      expect(audio.mediaType, 'audio');
      expect(audio.durationMs, 6200);
      expect(audio.transcript, 'two does and a fawn at the crossing');
      expect(File(audio.localPath!).existsSync(), isTrue);
      expect(
        p.isWithin(p.join(store.root.path, 'media', 'audio'), audio.localPath!),
        isTrue,
      );
      expect(
        voice.existsSync(),
        isFalse,
        reason: 'the temp recording is consumed once the save commits',
      );
    }, timeout: smokeTimeout);

    test('(c) capture without GPS is flagged, never faked', () async {
      final before = await countsOf(store.db);

      final written = await writeCapture(
        store.db,
        CaptureDraft(
          observationId: newId(),
          property: property,
          fix: null,
          fixIsLive: false,
          observationType: 'soil',
          notes: 'Caliche at the surface, no fix under the canopy.',
        ),
      );

      final after = await countsOf(store.db);
      expect(after.observations, before.observations + 1);
      expect(after.live, before.live + 1);
      expect(after.media, before.media, reason: 'a record without a photo');
      expect(after.mediaLinks, before.mediaLinks);

      final obs = await row(written.observationId);
      expect(obs.gpsAccuracyM, -1, reason: 'the "not located" convention');
      expect(obs.lat, property.centroidLat, reason: 'centroid stands in');
      expect(obs.lng, property.centroidLng);
      expect(obs.zoneId, isNull, reason: 'an unlocated record claims no zone');
      expect(
        obs.envContextId,
        isNotNull,
        reason: 'centroid weather is still the property weather',
      );

      // A stale last-known hint is displayed, never written.
      final hinted = await writeCapture(
        store.db,
        CaptureDraft(
          observationId: newId(),
          property: property,
          fix: fix,
          fixIsLive: false,
        ),
      );
      expect((await row(hinted.observationId)).gpsAccuracyM, -1);

      // Placed from the map: the pressed point is the location, accuracy
      // unknown.
      final placed = await writeCapture(
        store.db,
        CaptureDraft(
          observationId: newId(),
          property: property,
          placedLat: SmokeStore.lat + 0.001,
          placedLng: SmokeStore.lng + 0.001,
        ),
      );
      final placedRow = await row(placed.observationId);
      expect(placedRow.gpsAccuracyM, isNull);
      expect(placedRow.lat, SmokeStore.lat + 0.001);
      expect(placedRow.zoneId, isNotNull);
      expect((await countsOf(store.db)).live, before.live + 3);
    }, timeout: smokeTimeout);

    test('(d) editing notes and type changes the row and nothing else', () async {
      final photo = writeFile(p.join(scratch.path, 'shot.jpg'), smallJpeg());
      final written = await writeCapture(
        store.db,
        CaptureDraft(
          observationId: newId(),
          property: property,
          photos: [photo],
          fix: fix,
          fixIsLive: true,
          observationType: 'general',
          notes: 'something in the brush',
        ),
      );
      final before = await countsOf(store.db);
      final was = await row(written.observationId);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await applyRecordEdit(
        store.db,
        written.observationId,
        taxonId: null,
        taxonConfidence: 'unidentified',
        observationType: 'wildlife',
        observedAt: was.observedAt,
        notes: '  Feral hog rooting, fresh.  ',
      );

      final after = await countsOf(store.db);
      expect(after, before, reason: 'an edit adds and removes nothing');
      final now = await row(written.observationId);
      expect(now.observationType, 'wildlife');
      expect(now.notes, 'Feral hog rooting, fresh.');
      expect(now.taxonConfidence, 'unidentified');
      expect(now.updatedAt.compareTo(was.updatedAt), greaterThan(0));
      expect(now.lat, was.lat);
      expect(now.gpsAccuracyM, was.gpsAccuracyM);
      expect(now.zoneId, was.zoneId);
      expect(now.envContextId, was.envContextId);
      expect(now.deletedAt, isNull);
      expect((await linksOf(now.id)).single.role, 'primary');
    }, timeout: smokeTimeout);

    test('(e) soft delete tombstones; UNDO erases outright', () async {
      final photo = writeFile(p.join(scratch.path, 'a.jpg'), smallJpeg());
      final kept = await writeCapture(
        store.db,
        CaptureDraft(
          observationId: newId(),
          property: property,
          photos: [photo],
          fix: fix,
          fixIsLive: true,
          notes: 'stays',
        ),
      );
      final keptFiles = filesFor((await mediaOf(kept.observationId)).single);
      final base = await countsOf(store.db);

      // DELETE on the record screen: the record leaves the ledger, the row
      // and its photos stay, sync gets its tombstone.
      await softDeleteObservation(store.db, kept.observationId);
      var after = await countsOf(store.db);
      expect(after.observations, base.observations, reason: 'row kept');
      expect(after.live, base.live - 1, reason: 'but out of the ledger');
      expect(after.media, base.media);
      expect(after.mediaLinks, base.mediaLinks);
      expect((await row(kept.observationId)).deletedAt, isNotNull);
      for (final f in keptFiles) {
        expect(f.existsSync(), isTrue, reason: 'photos stay on disk');
      }

      // UNDO on the save toast: a seconds-old record is erased as if never
      // written — row, links, media, files, env context — and nothing
      // else is touched.
      final voice = fakeVoiceNote(scratch);
      final undone = await writeCapture(
        store.db,
        CaptureDraft(
          observationId: newId(),
          property: property,
          photos: [writeFile(p.join(scratch.path, 'b.jpg'), smallJpeg())],
          voice: voice,
          fix: fix,
          fixIsLive: true,
          notes: 'oops',
        ),
      );
      final undoneFiles = [
        for (final m in await mediaOf(undone.observationId)) ...filesFor(m),
      ];
      expect((await countsOf(store.db)).media, after.media + 2);
      for (final f in undoneFiles) {
        expect(f.existsSync(), isTrue);
      }

      await eraseObservation(store.db, undone.observationId);

      after = await countsOf(store.db);
      expect(after.observations, base.observations, reason: 'back to base');
      expect(after.live, base.live - 1, reason: 'the tombstone is untouched');
      expect(after.media, base.media);
      expect(after.mediaLinks, base.mediaLinks);
      expect(after.envContexts, base.envContexts);
      for (final f in undoneFiles) {
        expect(f.existsSync(), isFalse, reason: '${f.path} erased');
      }
      for (final f in keptFiles) {
        expect(f.existsSync(), isTrue, reason: 'the other record is whole');
      }
      // Idempotent, as a double-tap on UNDO would be.
      await eraseObservation(store.db, undone.observationId);
      expect(await countsOf(store.db), after);
    }, timeout: smokeTimeout);

    for (final encrypted in const [false, true]) {
      test(
        '(f) backup → restore into a fresh store keeps every count '
        '(${encrypted ? 'encrypted' : 'plain'})',
        () async {
          // Three records: photo, photo + voice, no photo. The photos
          // differ, or the second is one blob by content hash (correct,
          // and not what this case is about).
          for (var i = 0; i < 2; i++) {
            await writeCapture(
              store.db,
              CaptureDraft(
                observationId: newId(),
                property: property,
                photos: [
                  writeFile(
                    p.join(scratch.path, '$i.jpg'),
                    smallJpeg(width: 96 + 16 * i),
                  ),
                ],
                voice: i == 1 ? fakeVoiceNote(scratch) : null,
                fix: fix,
                fixIsLive: true,
                notes: 'record $i',
              ),
            );
          }
          await writeCapture(
            store.db,
            CaptureDraft(
              observationId: newId(),
              property: property,
              notes: 'no photo, no fix',
            ),
          );
          final source = await countsOf(store.db);
          expect(source.media, 3);
          final sourceShas = {
            for (final m in await store.db.select(store.db.media).get())
              m.sha256!,
          };

          // Back up to a local folder target, the way Settings does: a
          // plain cipher, or the keyring (small KDF here; the pipeline
          // reads the parameters back from the envelope).
          final targetDir = Directory(
            p.join(Directory.systemTemp.path, 'fn-smoke-target-${newId()}'),
          )..createSync();
          addTearDown(() => targetDir.deleteSync(recursive: true));
          const passphrase = 'correct horse battery staple';
          final BackupCipher cipher;
          Map<String, Object?>? envelope;
          if (encrypted) {
            final keyring = await BackupKeyring.create(
              passphrase,
              memoryKiB: 256,
              iterations: 1,
            );
            cipher = keyring.cipher;
            envelope = keyring.envelopeFields;
          } else {
            cipher = const PlainCipher();
          }
          final engine = BackupEngine(
            store.db,
            DirectoryTarget(targetDir),
            cipher,
            envelopeExtra: envelope,
            // The identification keys live in the device keystore; the
            // suite never reads or writes it.
            secretsProvider: () async => const {},
          );
          final summary = await engine.backup();
          expect(summary, contains('3 new photos'));
          expect(await engine.verify(), isNull);

          // The phone is gone. A fresh store restores from the folder:
          // stage, swap on "relaunch", open, remap media.
          await store.db.close();
          store.root.deleteSync(recursive: true);
          final fresh = Directory.systemTemp.createTempSync('fn-smoke-fresh-');
          addTearDown(() => fresh.deleteSync(recursive: true));
          SmokeStore.pointPathsAt(fresh);
          final pipeline = RestorePipeline(fresh);
          final staged = await pipeline.stageFromTarget(
            DirectoryTarget(targetDir),
            secret: encrypted ? passphrase : null,
          );
          expect(staged, contains('3 photos'));
          expect(pipeline.hasStagedRestore, isTrue);

          final livePath = p.join(fresh.path, 'field_notes.sqlite');
          expect(pipeline.applyStagedDb(livePath), isTrue);
          final restored = FieldNotesDb.fromFile(File(livePath));
          addTearDown(restored.close);
          expect(await countsOf(restored), source);

          final placed = await pipeline.remapRestoredMedia(restored);
          expect(placed, 3, reason: 'every blob finds its row');
          final rows = await restored.select(restored.media).get();
          expect({for (final m in rows) m.sha256!}, sourceShas);
          for (final m in rows) {
            final f = File(m.localPath!);
            expect(f.existsSync(), isTrue, reason: '${m.id} on disk');
            expect(p.isWithin(fresh.path, f.path), isTrue);
          }
          expect(pipeline.hasPendingMediaRemap, isFalse);

          // Leave `store` disposable: its root is already gone.
          store = await SmokeStore.open(label: 'fn-smoke-after-restore');
        },
        timeout: smokeTimeout,
      );
    }

    test('(g) a v9 database opens at the current schema with rows intact',
        () async {
      final file = File(p.join(scratch.path, 'old', 'field_notes.sqlite'));
      buildV9Fixture(file);

      final db = FieldNotesDb.fromFile(file);
      addTearDown(db.close);

      final kept = await (db.select(
        db.observations,
      )..where((o) => o.id.equals(v9ObservationId))).getSingle();
      expect(kept.notes, 'an old record');
      expect(kept.removalStatus, 'flagged');
      expect(kept.observationType, 'plant');
      final prop = await (db.select(
        db.properties,
      )..where((x) => x.id.equals(v9PropertyId))).getSingle();
      expect(prop.name, 'Old place');

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], db.schemaVersion);

      // What each step since v9 added is there: v10's type and tables,
      // v11's import register, v12's hidden flag.
      final now = nowUtcIso();
      await db
          .into(db.observations)
          .insert(
            ObservationsCompanion.insert(
              id: 'o2',
              propertyId: v9PropertyId,
              observedAt: now,
              localTz: 'CST',
              lat: 31.06,
              lng: -98.05,
              observationType: const Value('survey'),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
      expect(await db.select(db.protocols).get(), isEmpty);
      expect(await db.select(db.mapImports).get(), isEmpty);
      final zoneCols = {
        for (final r in await db.customSelect('PRAGMA table_info(zones)').get())
          r.data['name'] as String,
      };
      expect(zoneCols, containsAll(['import_id', 'hidden']));
      expect(await db.select(db.observations).get(), hasLength(2));
    }, timeout: smokeTimeout);
  });
}
