import 'dart:io';

import 'package:drift/drift.dart';

import '../db/database.dart';
import '../geo/zone_assignment.dart';
import 'diag.dart';
import 'env_context.dart';
import 'media_store.dart';
import 'observation_ops.dart';
import 'property_locator.dart';

/// The phone's position at the moment of saving — only the figures the
/// record needs, so the writer owes nothing to the location plugin and the
/// smoke suite can hand it a fix without one.
class CaptureFix {
  const CaptureFix({
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.altitudeM,
    this.headingDeg,
  });

  final double lat;
  final double lng;
  final double? accuracyM;
  final double? altitudeM;
  final double? headingDeg;
}

/// Everything the capture screen has gathered by the time SAVE is pressed.
/// Plain data: the screen builds one, [writeCapture] persists it.
class CaptureDraft {
  const CaptureDraft({
    required this.observationId,
    required this.property,
    this.photos = const [],
    this.voice,
    this.voiceDurationMs,
    this.voiceTranscript,
    this.placedLat,
    this.placedLng,
    this.fix,
    this.fixIsLive = false,
    this.observationType = 'general',
    this.taxonId,
    this.taxonChosenFromSuggestion = false,
    this.flagRemoval = false,
    this.notes,
    this.asPhotoPoint = false,
    this.photoPointSubject,
  });

  /// Reserved before the row exists, so capture-time identification can
  /// name the record it belongs to.
  final String observationId;
  final Property property;

  /// Every photo for this record, in the order taken; the first is primary.
  final List<File> photos;

  /// A recorded voice note, still at its temporary path. Moved into the
  /// media store on success and left where it is on failure, so a retry
  /// still has it.
  final File? voice;
  final int? voiceDurationMs;
  final String? voiceTranscript;

  /// Set when the record was dropped by long-pressing the map (spec §7.1):
  /// the location is the pressed point, not the phone's fix.
  final double? placedLat;
  final double? placedLng;
  bool get isPlaced => placedLat != null && placedLng != null;

  /// The current fix, if any, and whether it arrived from the live stream
  /// this session. A last-known hint is displayed but never written as a
  /// location.
  final CaptureFix? fix;
  final bool fixIsLive;

  final String observationType;
  final String? taxonId;

  /// A name picked from capture-time suggestions is 'probable', never
  /// 'certain'.
  final bool taxonChosenFromSuggestion;
  final bool flagRemoval;
  final String? notes;

  /// Pin a photo point at this spot too (same aim, every visit from here).
  final bool asPhotoPoint;
  final String? photoPointSubject;
}

/// What landed.
class CaptureWritten {
  const CaptureWritten({
    required this.observationId,
    required this.mediaIds,
    this.voiceMediaId,
  });

  final String observationId;

  /// Photo media ids, in link order.
  final List<String> mediaIds;
  final String? voiceMediaId;
}

/// The capture write path (design README §3.8), in the order the screen has
/// always done it. Photo files first — if the image can't be written we'd
/// rather have no record than a record that claims a photograph it doesn't
/// have — then one transaction for the observation, its env context, zone,
/// links and photo point. Never blocked on GPS, network or identification.
///
/// On any failure the media already written is taken back out so backups
/// and exports don't carry an orphan, and the error is rethrown for the
/// caller to show. The voice note's temporary file is consumed only once
/// everything has committed.
Future<CaptureWritten> writeCapture(
  FieldNotesDb db,
  CaptureDraft draft, {
  EnvContextService? envService,
}) async {
  final now = nowUtcIso();
  final fix = draft.fix;
  final placed = draft.isPlaced;
  final property = draft.property;
  final savedMediaIds = <String>[];
  String? savedVoiceId;

  try {
    for (final shot in draft.photos) {
      // Placed records: the photo's own GPS is the placed point too, so an
      // exported JPEG never leaks where the phone actually was.
      final media = await MediaStore(db).savePhoto(
        await shot.readAsBytes(),
        propertyId: property.id,
        createdBy: 'local',
        lat: placed ? draft.placedLat : fix?.lat,
        lng: placed ? draft.placedLng : fix?.lng,
        headingDeg: placed ? null : fix?.headingDeg,
        capturedAt: now,
      );
      savedMediaIds.add(media.id);
    }

    // Voice note: audio kept as media (spec §3.5 — never discard the
    // audio); the transcript is already in the notes text.
    MediaData? voice;
    final voiceFile = draft.voice;
    if (voiceFile != null && voiceFile.existsSync()) {
      final transcript = draft.voiceTranscript?.trim();
      voice = await MediaStore(db).saveAudio(
        voiceFile,
        propertyId: property.id,
        createdBy: 'local',
        lat: placed ? draft.placedLat : fix?.lat,
        lng: placed ? draft.placedLng : fix?.lng,
        capturedAt: now,
        durationMs: draft.voiceDurationMs,
        transcript: transcript == null || transcript.isEmpty
            ? null
            : transcript,
      );
      savedVoiceId = voice.id;
    }

    // Placed on the map: the pressed point IS the location (accuracy
    // unknown → null). Otherwise, no LIVE fix → the property centroid (or
    // the last-known hint) stands in so the record still lands on the map,
    // but gps_accuracy_m = -1 flags it. Never a silent fake.
    final located = placed || (fix != null && draft.fixIsLive);
    final lat = placed ? draft.placedLat : fix?.lat ?? property.centroidLat;
    final lng = placed ? draft.placedLng : fix?.lng ?? property.centroidLng;
    final env = envService ?? EnvContextService(db);
    final notes = draft.notes?.trim();

    await db.transaction(() async {
      // Environmental context: created stale now, backfilled when online
      // (spec §4.11). Centroid weather is still the property's weather.
      String? envContextId;
      if (lat != null && lng != null) {
        envContextId = await env.createStale(
          propertyId: property.id,
          lat: lat,
          lng: lng,
          resolvedFor: now.substring(0, 10),
        );
      }

      await db
          .into(db.observations)
          .insert(
            ObservationsCompanion.insert(
              id: draft.observationId,
              propertyId: property.id,
              observedAt: now,
              localTz: localTzName(),
              lat: lat ?? 0,
              lng: lng ?? 0,
              // Placed: accuracy unknown (null). Live fix: the GPS figure.
              // Otherwise -1 = "not located", never a fake.
              gpsAccuracyM: Value(
                placed
                    ? null
                    : located
                    ? fix!.accuracyM
                    : -1,
              ),
              altitudeM: Value(fix?.altitudeM),
              headingDeg: Value(fix?.headingDeg),
              observationType: Value(
                draft.taxonId != null && draft.observationType == 'general'
                    ? 'plant'
                    : draft.observationType,
              ),
              taxonId: Value(draft.taxonId),
              removalStatus: Value(draft.flagRemoval ? 'flagged' : null),
              taxonConfidence: Value(
                draft.taxonId == null
                    ? null
                    : draft.taxonChosenFromSuggestion
                    ? 'probable'
                    : 'certain',
              ),
              notes: Value(notes == null || notes.isEmpty ? null : notes),
              envContextId: Value(envContextId),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );

      if (located && lat != null && lng != null) {
        await assignZone(
          db,
          observationId: draft.observationId,
          propertyId: property.id,
          lat: lat,
          lng: lng,
        );
        // The first located record on a placeless property tells the app
        // where the place is and what state it sits in.
        await PropertyLocator(db).noteLocation(property.id, lat, lng);
      }

      for (var i = 0; i < savedMediaIds.length; i++) {
        await MediaStore(db).linkTo(
          savedMediaIds[i],
          propertyId: property.id,
          entityType: 'observation',
          entityId: draft.observationId,
          role: i == 0 ? 'primary' : 'attachment',
        );
      }

      // A station, pinned from the field: same spot, same aim, every visit
      // from here on. The first ghost capture refines the bearing.
      if (draft.asPhotoPoint && lat != null && lng != null) {
        final heading = fix?.headingDeg;
        await db
            .into(db.photoPoints)
            .insert(
              PhotoPointsCompanion.insert(
                id: newId(),
                propertyId: property.id,
                name: notes != null && notes.isNotEmpty
                    ? notes.split('\n').first
                    : 'Photo point ${now.substring(0, 10)}',
                lat: lat,
                lng: lng,
                bearingDeg: heading != null && heading >= 0 ? heading : 0,
                subject: Value(draft.photoPointSubject),
                cadenceDays: const Value(90),
                focalLengthMm: const Value(26),
                viewExtentM: const Value(60),
                referenceMediaId: Value(
                  savedMediaIds.isEmpty ? null : savedMediaIds.first,
                ),
                createdBy: 'local',
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      if (voice != null) {
        await MediaStore(db).linkTo(
          voice.id,
          propertyId: property.id,
          entityType: 'observation',
          entityId: draft.observationId,
          role: 'attachment', // schema CHECK; media_type = 'audio' marks it
        );
      }
    });
  } catch (e) {
    // The photo may already be in the media store with no record to own
    // it; take it back out so backups and exports don't carry an orphan.
    // The save is the failure worth showing; a cleanup that also fails is
    // said out loud in the log, not hidden and not promoted over it.
    for (final id in [...savedMediaIds, ?savedVoiceId]) {
      try {
        await eraseMedia(db, id);
      } catch (cleanup, st) {
        Diag.report(
          cleanup,
          st,
          where: 'writeCapture.cleanup',
          extra: {'save_error': '$e', 'media': id},
        );
      }
    }
    rethrow;
  }

  // Committed: the recording lives in the media store now.
  if (savedVoiceId != null) {
    final voiceFile = draft.voice;
    if (voiceFile != null && voiceFile.existsSync()) {
      try {
        voiceFile.deleteSync();
      } catch (e, st) {
        // The record is whole; a stale temp file only costs disk.
        Diag.report(e, st, where: 'writeCapture.voiceTemp');
      }
    }
  }

  return CaptureWritten(
    observationId: draft.observationId,
    mediaIds: List.unmodifiable(savedMediaIds),
    voiceMediaId: savedVoiceId,
  );
}
