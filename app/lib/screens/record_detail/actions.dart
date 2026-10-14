part of '../record_detail_screen.dart';

/// What can be done from here: identify, add photos, make a station,
/// the monitoring run, removal, EDIT and DELETE.
mixin _RecordActions on _RecordEdits {
  List<Widget> _actionChildren(Observation obs) => [
          // 5c. Identify: only where there's a photograph to work from.
          if (_photos.isNotEmpty && _property != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                12,
              ),
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.eco_outlined),
                  label: Text(
                    _taxon == null ? 'WHAT IS IT?' : 'SUGGEST ANOTHER SPECIES',
                  ),
                  onPressed: () async {
                    final accepted = await showIdentifySheet(
                      context,
                      db: widget.db,
                      observation: _obs!,
                      property: _property!,
                      // Every photo of the record goes to Pl@ntNet (up to five).
                      photos: [for (final p in _photos) File(p.localPath!)],
                    );
                    if (accepted) _load();
                  },
                ),
              ),
            ),

          // Photos can be added after the fact — from the camera on the
          // phone, from files on the desk — without pretending they were
          // taken where the record was.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Metrics.gutter,
              0,
              Metrics.gutter,
              12,
            ),
            child: SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add_a_photo_outlined),
                label: const Text('ADD PHOTOS'),
                onPressed: _addPhotos,
              ),
            ),
          ),

          // A species record can become a station (Austin, 2026-09-07:
          // "each species record should also have a photo pts option"):
          // same spot, same aim, the record's photo as the anchor frame.
          if (_photos.isNotEmpty && obs.gpsAccuracyM != -1)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                12,
              ),
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  icon: Icon(
                    _photoPoint == null
                        ? Icons.center_focus_weak
                        : Icons.center_focus_strong,
                  ),
                  label: Text(
                    _photoPoint == null
                        ? 'MAKE A PHOTO POINT'
                        : 'PHOTO POINT ✓ · OPEN',
                  ),
                  onPressed: _photoPoint == null
                      ? _makePhotoPoint
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PhotoPointHistoryScreen(
                              db: widget.db,
                              point: _photoPoint!,
                            ),
                          ),
                        ),
                ),
              ),
            ),

          // Monitoring (D-033): the run this record was made as — the
          // method, the site, and what the answers add up to.
          if (_run != null && _runProtocol != null && _runSite != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                12,
              ),
              child: RunSummaryCard(
                protocol: _runProtocol!,
                site: _runSite!,
                run: _run!,
                indicators: _runIndicators,
                onOpenSite: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SiteDetailScreen(
                      db: widget.db,
                      protocol: _runProtocol!,
                      site: _runSite!,
                    ),
                  ),
                ),
              ),
            ),

          // Removal (D-027): flag it, then say when it came out. Pulling
          // ashe juniper, mesquite and chinaberry is restoration work as
          // much as planting is (Austin, 2026-09-07).
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Metrics.gutter,
              0,
              Metrics.gutter,
              12,
            ),
            child: switch (obs.removalStatus) {
              null => SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Press.oxblood,
                    side: BorderSide(color: Press.oxblood, width: 1.5),
                  ),
                  icon: const Icon(Icons.content_cut),
                  label: const Text('FLAG FOR REMOVAL'),
                  onPressed: () => _setRemoval('flagged'),
                ),
              ),
              'flagged' => Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Press.oxblood,
                        ),
                        icon: const Icon(Icons.check),
                        label: const Text('MARK REMOVED'),
                        onPressed: () => _setRemoval('removed'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      onPressed: () => _setRemoval(null),
                      child: const Text('CLEAR FLAG'),
                    ),
                  ),
                ],
              ),
              _ => SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.undo),
                  label: Text(
                    'REMOVED${obs.removedOn != null ? ' ${obs.removedOn}' : ''} · REOPEN',
                  ),
                  onPressed: () => _setRemoval('flagged'),
                ),
              ),
            },
          ),

          // 6. Actions.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Metrics.gutter,
              0,
              Metrics.gutter,
              24,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: FilledButton(
                      onPressed: _editRecord,
                      child: const Text('EDIT'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _delete,
                    child: const Text('DELETE'),
                  ),
                ),
              ],
            ),
          ),
  ];
}
