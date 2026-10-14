part of '../capture_screen.dart';

mixin _CaptureFormStep on _CaptureSave {
  // Step 1 — the form.
  Widget _buildForm() {
    final fix = _fix;
    return Container(
      color: Press.paper,
      child: Column(
        children: [
          // Header strip.
          Container(
            padding: EdgeInsets.fromLTRB(13, 10, 6, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Press.ink,
                  width: Metrics.borderStructural,
                ),
              ),
            ),
            child: Row(
              children: [
                Diamond(size: 9, color: Press.sage),
                SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MonoLabel(
                        _shots.isEmpty
                            ? 'No photo'
                            : _shots.length == 1
                            ? 'Photo taken'
                            : '${_shots.length} photos',
                        size: 9.5,
                        spacing: 1.6,
                        color: Press.sage,
                      ),
                      SizedBox(height: 2),
                      MonoLabel(
                        widget.isPlaced
                            ? 'Placed on the map · ${widget.placedLat!.toStringAsFixed(5)}, ${widget.placedLng!.toStringAsFixed(5)}'
                            : fix == null
                            ? 'No GPS fix — saved without a location'
                            : !_zoneResolved
                            ? 'GPS ±${fix.accuracy.toStringAsFixed(0)} m'
                            : _zoneName != null
                            ? 'GPS ±${fix.accuracy.toStringAsFixed(0)} m · $_zoneName'
                            : 'GPS ±${fix.accuracy.toStringAsFixed(0)} m · ${noZoneLabel(_zoneCount)}',
                        size: 8.5,
                        opacity: 0.65,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: TextButton(
                    onPressed: _confirmDiscard,
                    child: Text('✕'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.all(Metrics.gutter),
              children: [
                // More photos, and a machine's opinion before you name it.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: _asPhotoPoint ? Press.ink : null,
                          foregroundColor: _asPhotoPoint
                              ? Press.paper
                              : Press.ink,
                        ),
                        icon: Icon(
                          _asPhotoPoint
                              ? Icons.center_focus_strong
                              : Icons.center_focus_weak,
                          size: 18,
                        ),
                        label: Text(
                          _asPhotoPoint ? 'PHOTO POINT ✓' : 'PHOTO POINT',
                        ),
                        onPressed: () =>
                            setState(() => _asPhotoPoint = !_asPhotoPoint),
                      ),
                    ),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: _flagRemoval ? Press.oxblood : null,
                          foregroundColor: _flagRemoval
                              ? Press.paper
                              : Press.oxblood,
                          side: BorderSide(color: Press.oxblood, width: 1.5),
                        ),
                        icon: Icon(Icons.content_cut, size: 18),
                        label: Text(
                          _flagRemoval ? 'REMOVAL ✓' : 'FLAG FOR REMOVAL',
                        ),
                        onPressed: () =>
                            setState(() => _flagRemoval = !_flagRemoval),
                      ),
                    ),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        icon: Icon(Icons.photo_camera_outlined, size: 18),
                        label: Text(
                          _shots.isEmpty ? 'TAKE A PHOTO' : 'ANOTHER PHOTO',
                        ),
                        onPressed: () => setState(() => _step = 0),
                      ),
                    ),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        icon: Icon(Icons.photo_library_outlined, size: 18),
                        label: Text('FROM GALLERY'),
                        onPressed: _pickFromGallery,
                      ),
                    ),
                    if (_shots.isNotEmpty)
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          icon: Icon(Icons.eco_outlined, size: 18),
                          label: Text('SUGGEST A SPECIES'),
                          onPressed: _suggestSpecies,
                        ),
                      ),
                  ],
                ),
                if (_shots.isNotEmpty) ...[
                  SizedBox(height: 12),
                  // The photos in hand (Austin, 2026-09-07: "you don't see
                  // the image, much less the other 3-4 you took"). Every
                  // one goes on the record; the identify sheet is where
                  // you pick which go to Pl@ntNet.
                  SizedBox(
                    height: 84,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _shots.length,
                      separatorBuilder: (_, _) => SizedBox(width: 8),
                      itemBuilder: (context, i) => Stack(
                        children: [
                          Container(
                            width: 84,
                            height: 84,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Press.borderInk,
                                width: 1.5,
                              ),
                              image: DecorationImage(
                                image: FileImage(File(_shots[i].path)),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            right: 0,
                            child: GestureDetector(
                              onTap: () => setState(() => _shots.removeAt(i)),
                              child: Container(
                                width: 28,
                                height: 28,
                                color: Press.ink,
                                child: Icon(
                                  Icons.close,
                                  size: 16,
                                  color: Press.paper,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: MonoLabel(
                        _taxon == null
                            ? 'What is it? · optional — favourites first'
                            : 'What is it? · ${_taxon!.scientificName}',
                        size: 9,
                        spacing: 1.8,
                      ),
                    ),
                    if (_taxon?.nativity != null)
                      NativityChip(_taxon!.nativity),
                  ],
                ),
                SizedBox(height: 8),
                SpeciesField(
                  db: widget.db,
                  label: 'Species — common or Latin name',
                  onSelected: (t) => setState(() {
                    _taxon = t;
                    // Naming a plant makes this a plant record unless the
                    // user already chose something more specific.
                    if (t != null && _observationType == 'general') {
                      _observationType = 'plant';
                    }
                  }),
                ),
                SizedBox(height: 16),
                MonoLabel('What kind of record', size: 9, spacing: 1.8),
                SizedBox(height: 8),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final t in kObservationTypes)
                      GestureDetector(
                        onTap: () => setState(() => _observationType = t),
                        child: Container(
                          height: 56, // glove target (spec §7)
                          padding: EdgeInsets.symmetric(horizontal: 18),
                          decoration: BoxDecoration(
                            color: _observationType == t ? Press.ink : null,
                            border: Border.all(
                              color: Press.borderInk,
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          // Center(widthFactor) keeps the pill hugging its
                          // label; a Container with `alignment` would grow
                          // to the Wrap's full width.
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              t.toUpperCase(),
                              style: TextStyle(
                                fontFamily: Type.mono,
                                fontSize: 9.5,
                                letterSpacing: 1.4,
                                color: _observationType == t
                                    ? Press.paper
                                    : Press.ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: 16),
                MonoLabel('Saved with this record', size: 9, spacing: 1.8),
                SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Press.paperRaised,
                    border: Border.all(color: Press.borderInk, width: 1.5),
                  ),
                  child: Column(
                    children: [
                      FactRow('when', _localNow()),
                      FactRow(
                        'where',
                        widget.isPlaced
                            ? '${widget.placedLat!.toStringAsFixed(5)}, ${widget.placedLng!.toStringAsFixed(5)}  placed on map'
                            : fix != null
                            ? '${fix.latitude.toStringAsFixed(5)}, ${fix.longitude.toStringAsFixed(5)}  ±${fix.accuracy.toStringAsFixed(0)} m'
                            : 'no fix — flagged, never faked',
                      ),
                      FactRow(
                        'weather · soil',
                        'looked up when you\'re back online',
                        last: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Footer.
          Container(
            padding: EdgeInsets.all(Metrics.gutter),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Press.divider, width: 1)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 58,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'WRITING…' : 'SAVE OBSERVATION'),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                SizedBox(
                  height: 58,
                  width: 58,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                    // Dictating beats typing with gloves on: one tap from
                    // the photo to a running recording (spec §7.2).
                    onPressed: () {
                      setState(() => _step = 2);
                      _toggleVoice();
                    },
                    child: Icon(Icons.mic_none, size: 22),
                  ),
                ),
                SizedBox(width: 8),
                SizedBox(
                  height: 58,
                  child: OutlinedButton(
                    onPressed: () => setState(() => _step = 2),
                    child: Text('+ NOTES'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
