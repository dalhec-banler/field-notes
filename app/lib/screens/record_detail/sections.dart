part of '../record_detail_screen.dart';

/// The fact card, the condition timeline, notes, voice notes and what
/// else is within 50 m.
mixin _RecordSections on _RecordEdits {
  List<Widget> _sectionChildren(Observation obs, String when) => [
          // 3. Fact card — schema field names as keys.
          Padding(
            padding: EdgeInsets.all(Metrics.gutter),
            child: Container(
              decoration: BoxDecoration(
                color: Press.paperRaised,
                border: Border.all(color: Press.borderInk, width: 1.5),
              ),
              child: Column(
                children: [
                  FactRow('when', '$when ${obs.localTz}'),
                  InkWell(
                    // Tap the place line → the map, showing ONLY this
                    // species (Austin, 2026-09-04). No species: no jump.
                    onTap: obs.taxonId == null || obs.gpsAccuracyM == -1
                        ? null
                        : () {
                            _scope.recordFilter.update((f) {
                              f.taxonId = obs.taxonId;
                              f.taxonLabel =
                                  _taxon?.commonName ??
                                  _taxon?.scientificName ??
                                  'species';
                            });
                            _scope.recordFilter.jumpToMap();
                            if (!widget.embedded) {
                              Navigator.of(context).popUntil((r) => r.isFirst);
                            }
                          },
                    child: FactRow(
                      'where',
                      obs.gpsAccuracyM == -1
                          ? 'no GPS fix — flagged, never faked'
                          : '${obs.lat.toStringAsFixed(5)}, ${obs.lng.toStringAsFixed(5)}'
                                '${obs.gpsAccuracyM != null ? '  ±${obs.gpsAccuracyM!.toStringAsFixed(0)} m' : ''}'
                                '${obs.taxonId != null ? '  ·  ⌖ all on map' : ''}',
                    ),
                  ),
                  FactRow('zone', _zone?.name ?? noZoneLabel(_zoneCount)),
                  if (_env != null) ...[
                    FactRow(
                      'rain, 30 d',
                      // True whether the lookup is switched off or simply
                      // hasn't run yet — the old copy promised a lookup that
                      // may never happen now that it's opt-in (D-022).
                      _env!.isStale == 1
                          ? 'not looked up'
                          : '${_env!.precip30dMm?.toStringAsFixed(1) ?? '—'} mm · '
                                '${_env!.daysSinceRain ?? '—'} d since rain',
                    ),
                    if (_env!.soilSeries != null)
                      FactRow(
                        'soil',
                        [
                          _env!.soilSeries!,
                          if (_env!.soilDrainageClass != null)
                            _env!.soilDrainageClass!,
                        ].join(' · '),
                      ),
                  ],
                  if (_photos.isNotEmpty)
                    FactRow(
                      'photos',
                      '${_photos.length} · on this phone only',
                      last: _audio.isEmpty,
                    ),
                  if (_audio.isNotEmpty)
                    FactRow(
                      'voice',
                      '${_audio.length} note${_audio.length == 1 ? '' : 's'} · on this phone only',
                      last: true,
                    ),
                  if (_photos.isEmpty && _audio.isEmpty)
                    FactRow('media', 'none', last: true),
                ],
              ),
            ),
          ),

          // Condition — the merged feature timeline (2026-09-04): a spring,
          // a gate, a diseased oak — any record can carry one.
          Padding(
            padding: EdgeInsets.fromLTRB(Metrics.gutter, 0, Metrics.gutter, 14),
            child: StreamBuilder<List<ConditionLog>>(
              stream: _records.watchConditionLogs(obs.id),
              builder: (context, snapshot) {
                final logs = snapshot.data ?? const <ConditionLog>[];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        // Kicker stretches its rule with an Expanded; as a
                        // plain Row child its width is unbounded and layout
                        // throws — every record with this section red-screens
                        // (audit 2026-09-05). Give it the bounded slot.
                        Expanded(child: Kicker('Condition')),
                        if (logs.isNotEmpty)
                          StatusPill(
                            logs.first.condition.toUpperCase(),
                            color: conditionColor(logs.first.condition),
                            filled: true,
                          ),
                      ],
                    ),
                    SizedBox(height: 6),
                    for (final l in logs)
                      InkWell(
                        onTap: () => _editConditionLog(l),
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Diamond(
                                size: 10,
                                color: conditionColor(l.condition),
                                filled: true,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  [
                                    '${l.observedAt.substring(0, 10)} · '
                                        '${l.condition}',
                                    if (l.actionTaken != null) l.actionTaken!,
                                    if (l.notes != null) l.notes!,
                                  ].join(' · '),
                                  style: TextStyle(
                                    fontFamily: Type.serif,
                                    fontSize: 14.5,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    SizedBox(height: 4),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton(
                        onPressed: () => showConditionLogDialog(
                          context,
                          db: widget.db,
                          obs: obs,
                        ),
                        child: Text('LOG CONDITION'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          // Notes.
          if (obs.notes != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                14,
              ),
              child: Text(
                obs.notes!,
                style: TextStyle(
                  fontFamily: Type.serif,
                  fontSize: 16,
                  height: 1.5,
                ),
              ),
            ),

          // 5. Voice notes — the audio is the record; the transcript is
          // already in the notes above.
          for (final a in _audio)
            Padding(
              padding: EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                12,
              ),
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  icon: Icon(
                    _playingId == a.id ? Icons.stop : Icons.play_arrow,
                  ),
                  label: Text(
                    _playingId == a.id
                        ? 'STOP'
                        : 'VOICE NOTE · ${_fmtMs(a.durationMs)}',
                  ),
                  onPressed: () => _play(a),
                ),
              ),
            ),

          // 5b. Related: other records within 50 m (spec §7.4) — the return
          // visit is the whole point (core principle 4).
          if (_nearby.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                Metrics.gutter,
                4,
                Metrics.gutter,
                14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MonoLabel('Nearby · within 50 m', size: 9, spacing: 1.8),
                  const SizedBox(height: 4),
                  for (final (o, d) in _nearby)
                    InkWell(
                      onTap: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) =>
                              RecordDetailScreen(db: widget.db, obsId: o.id),
                        ),
                      ),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 52),
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Press.divider, width: 1),
                          ),
                        ),
                        child: Row(
                          children: [
                            Diamond(
                              size: 7,
                              color: recordTypeColor(o.observationType),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                [
                                  _fmtDate(o.observedAt),
                                  o.observationType,
                                  if (o.notes != null) o.notes!,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: Type.serif,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            MonoLabel(
                              '${d.toStringAsFixed(0)} m',
                              size: 9,
                              opacity: 0.7,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
  ];
}
