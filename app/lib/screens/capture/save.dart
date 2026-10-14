part of '../capture_screen.dart';

/// Naming the species before the row exists, the write itself, and the
/// discard guard.
mixin _CaptureSave on _CaptureCore {
  /// Ask for an ID before the record exists. The suggestions are kept in
  /// memory and written the moment the row is saved (rule 7); a picked
  /// name fills the species field as "probable", never "certain".
  Future<void> _suggestSpecies() async {
    if (_shots.isEmpty) return;
    final now = nowUtcIso();
    final fix = _fix;
    final lat = widget.isPlaced
        ? widget.placedLat
        : fix?.latitude ?? widget.property.centroidLat;
    final lng = widget.isPlaced
        ? widget.placedLng
        : fix?.longitude ?? widget.property.centroidLng;
    final transient = Observation(
      id: _obsId,
      propertyId: widget.property.id,
      zoneId: null,
      observedAt: now,
      localTz: DateTime.now().timeZoneName,
      lat: lat ?? 0,
      lng: lng ?? 0,
      gpsAccuracyM: lat == null ? -1 : (widget.isPlaced ? null : fix?.accuracy),
      observationType: 'plant',
      isSuggestion: 0,
      createdBy: 'local',
      createdAt: now,
      updatedAt: now,
    );
    final service = IdentificationService(widget.db);
    try {
      await showIdentifySheet(
        context,
        db: widget.db,
        observation: transient,
        property: widget.property,
        photos: [for (final x in _shots) File(x.path)],
        persist: false,
        onCandidates: (c) => _pendingSuggestions = c,
        onChoose: (c) async {
          final taxonId = await service.ensureTaxon(c, widget.property.id);
          final taxon = await _taxa.byId(taxonId);
          if (!mounted) return;
          setState(() {
            _taxon = taxon;
            _chosenCandidate = c;
            if (_observationType == 'general') _observationType = 'plant';
          });
        },
      );
    } finally {
      service.close();
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final started = DateTime.now();
    final db = widget.db;
    final fix = _fix;
    final obsId = _obsId;

    final voicePath = _voicePath;
    final envService = EnvContextService(db);
    try {
      // The write itself lives in one place (services/capture_writer.dart)
      // so the smoke suite saves records the way this screen does. Photo
      // first, then one transaction; a failure leaves nothing behind.
      final written = await writeCapture(
        db,
        CaptureDraft(
          observationId: obsId,
          property: widget.property,
          photos: [
            for (final shot in _shots)
              if (shot.path.isNotEmpty) File(shot.path),
          ],
          voice: voicePath == null ? null : File(voicePath),
          voiceDurationMs: _voiceMs,
          voiceTranscript: _voice.transcript,
          placedLat: widget.placedLat,
          placedLng: widget.placedLng,
          fix: fix == null
              ? null
              : CaptureFix(
                  lat: fix.latitude,
                  lng: fix.longitude,
                  accuracyM: fix.accuracy,
                  altitudeM: fix.altitude,
                  headingDeg: fix.heading,
                ),
          fixIsLive: _fixIsLive,
          observationType: _observationType,
          taxonId: _taxon?.id,
          taxonChosenFromSuggestion: _chosenCandidate != null,
          flagRemoval: _flagRemoval,
          notes: _notesController.text,
          asPhotoPoint: _asPhotoPoint,
          photoPointSubject: _taxon?.commonName ?? _taxon?.scientificName,
        ),
        envService: envService,
      );
      if (written.voiceMediaId != null) {
        // The recording is in the media store; nothing left to discard.
        _voiceSaved = true;
        _voicePath = null;
      }
      unawaited(envService.backfillStale());

      if (mounted) {
        // Capture-time suggestions now have a row to belong to (rule 7).
        if (_pendingSuggestions.isNotEmpty) {
          final svc = IdentificationService(db);
          try {
            final row = await _records.single(obsId);
            final rid = await svc.recordSuggestions(_pendingSuggestions, row);
            final chosen = _chosenCandidate;
            if (chosen != null) {
              await svc.accept(
                candidate: chosen,
                observationId: obsId,
                propertyId: widget.property.id,
                runId: rid,
              );
            }
          } catch (e, st) {
            Diag.report(e, st, where: 'CaptureScreen._save');
            // The record is saved; a missing suggestion row is not worth a scare.
          } finally {
            svc.close();
          }
        }
        // Identification can run long; if the capture screen has already
        // been left by then, there is nothing to pop.
        if (!mounted) return;
        Navigator.of(context)
            .pop(CaptureResult(obsId, DateTime.now().difference(started)));
      }
    } catch (e) {
      // writeCapture has already taken back any media it wrote, and the
      // voice note's temp file is still where it was, so SAVE can be tried
      // again with everything still in hand.
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed — nothing written. $e')),
      );
    }
  }

  String _localNow() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)} '
        '${localTzName()}';
  }

  /// Back / ✕ on the form steps: a photo and a half-filled form are worth a
  /// question before they vanish.
  Future<void> _confirmDiscard() async {
    if (_saving) return; // the write is in flight; let it land
    final dirty =
        _shots.isNotEmpty ||
        _taxon != null ||
        _notesController.text.trim().isNotEmpty;
    if (!dirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('DISCARD THIS RECORD?'),
        content: Text('The photo and anything you filled in will be dropped.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('KEEP'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('DISCARD'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }
}
