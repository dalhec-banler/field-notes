part of '../record_detail_screen.dart';

/// Every write the record screen makes: photos on and off, condition
/// entries, the station, removal, the edit sheet, the pin, delete.
mixin _RecordEdits on _RecordDetailCore {
  /// Remove ONE picture from this record (Austin, 2026-09-01). The link
  /// goes first; the file itself is erased only when no other record still
  /// uses it (photos are content-deduplicated across records).
  Future<void> _deleteCurrentPhoto() async {
    final obs = _obs;
    if (obs == null || _photos.isEmpty) return;
    final media = _photos[_photoIndex];
    final sure = await confirmDialog(
      context,
      title: 'REMOVE THIS PHOTO?',
      body: _photos.length == 1
          ? 'The record keeps its facts and notes; its only photo goes.'
          : 'Photo ${_photoIndex + 1} of ${_photos.length} comes off '
                'this record.',
      cancelLabel: 'KEEP',
      confirmLabel: 'REMOVE',
    );
    if (!sure) return;
    await _media.unlink(media.id, entityId: obs.id);
    if (await _media.liveLinkCount(media.id) == 0) {
      await _media.erase(media.id, log: _scope.opLog);
    }
    _photoIndex = 0;
    await _load();
  }

  Future<void> _addPhotos() async {
    final obs = _obs;
    if (obs == null) return;
    final picker = ImagePicker();
    List<XFile> picked = [];
    try {
      if (isDesk) {
        picked = await picker.pickMultiImage();
      } else {
        final source = await showModalBottomSheet<ImageSource>(
          context: context,
          backgroundColor: Press.paper,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take a photo'),
                  onTap: () => Navigator.pop(ctx, ImageSource.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose from gallery'),
                  onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
        if (source == null) return;
        if (source == ImageSource.camera) {
          final one = await picker.pickImage(source: source, imageQuality: 92);
          if (one != null) picked = [one];
        } else {
          picked = await picker.pickMultiImage(imageQuality: 92);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open photos: $e')));
      }
      return;
    }
    if (picked.isEmpty) return;
    final store = MediaStore(widget.db);
    for (final x in picked) {
      final media = await store.savePhoto(
        await x.readAsBytes(),
        propertyId: obs.propertyId,
        createdBy: 'local',
        capturedAt: nowUtcIso(),
      );
      await store.linkTo(
        media.id,
        propertyId: obs.propertyId,
        entityType: 'observation',
        entityId: obs.id,
        role: _photos.isEmpty ? 'primary' : 'attachment',
      );
    }
    await _load();
  }


  /// Edit what a field ID most often gets wrong (shared editor, see
  /// widgets/edit_record_sheet.dart). MOVE THE PIN comes back here because
  /// it needs the map.
  static const _conditions = [
    ('good', 'Good'),
    ('fair', 'Fair'),
    ('poor', 'Poor'),
    ('critical', 'Critical'),
    ('unknown', 'Unknown'),
  ];

  Future<void> _editConditionLog(ConditionLog l) async {
    final r = await showEditSheet(
      context,
      title: 'Edit condition',
      fields: [
        DateEdit('on', 'Observed on', initial: l.observedAt),
        ChoiceEdit(
          'condition',
          'Condition',
          options: _conditions,
          initial: l.condition,
        ),
        TextEdit('action', 'Action taken', initial: l.actionTaken),
        TextEdit('notes', 'Notes', initial: l.notes, lines: 2),
      ],
      deleteTitle: 'DELETE THIS CONDITION ENTRY?',
    );
    if (r == null) return;
    if (r.deleted) {
      await _records.softDeleteConditionLog(l.id);
      return;
    }
    await _records.updateConditionLog(
      l.id,
      observedAt: withDay(l.observedAt, r.day('on') ?? l.observedAt),
      condition: r.text('condition') ?? l.condition,
      actionTaken: r.text('action'),
      notes: r.text('notes'),
    );
  }

  Future<void> _makePhotoPoint() async {
    final obs = _obs!;
    final name =
        _taxon?.commonName ??
        _taxon?.scientificName ??
        'Photo point ${obs.observedAt.substring(0, 10)}';
    final heading = obs.headingDeg;
    await _photoPoints.create(
      propertyId: obs.propertyId,
      name: name,
      lat: obs.lat,
      lng: obs.lng,
      bearingDeg: heading != null && heading >= 0 ? heading : 0,
      subject: _taxon?.commonName ?? _taxon?.scientificName,
      referenceMediaId: _photos.first.id,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('PHOTO POINT · $name — find it under Photo points'),
      ),
    );
    _load();
  }

  Future<void> _setRemoval(String? status) async {
    await _records.setRemoval(widget.obsId, status);
    _load();
  }

  Future<void> _editRecord() async {
    final obs = _obs;
    if (obs == null) return;
    final outcome = await showEditRecordSheet(
      context,
      db: widget.db,
      obs: obs,
      taxon: _taxon,
      // The pin moves on a map, and the desk has none yet.
      allowMovePin: !isDesk,
    );
    if (!mounted) return;
    if (outcome == EditOutcome.movePin) {
      await _movePin(obs);
      return;
    }
    if (outcome == EditOutcome.saved) _load();
  }

  /// Hand-adjust the record's location, then keep the derived facts honest:
  /// accuracy becomes "placed by hand" (null — the same meaning the capture
  /// flow gives a map-drop), and the zone is re-derived from the new point,
  /// including clearing it when the pin moves outside every zone.
  Future<void> _movePin(Observation obs) async {
    final moved = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => MovePinScreen(lat: obs.lat, lng: obs.lng),
      ),
    );
    if (moved == null) return;
    await _records.moveTo(obs, lat: moved.latitude, lng: moved.longitude);
    _load();
  }

  Future<void> _delete() async {
    final confirmed = await confirmDialog(
      context,
      title: 'DELETE RECORD?',
      body: 'The record leaves your ledger. Photos stay on disk.',
      confirmLabel: 'DELETE',
    );
    if (!confirmed) return;
    // Soft delete (spec §4.1) — sync engines need tombstones.
    await _records.softDelete(widget.obsId);
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (!widget.embedded && nav.canPop()) nav.pop();
  }
}
