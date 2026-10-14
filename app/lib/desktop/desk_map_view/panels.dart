part of '../desk_map_view.dart';

/// The side panels: species, a clicked feature, a selected record.
mixin _DeskMapPanels on _DeskMapMarks {
  /// The species panel: what lives on this map, most-seen first. Click a
  /// species — its card opens in place, everything else slides down, and
  /// its marks light up while the rest of the map dims.
  Widget _speciesPanel(MapLayerSet s) {
    final groups = _groups;
    if (groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No records on this map yet. The phone captures; this desk '
            'reviews them in place.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 14.5,
              height: 1.5,
              color: Press.inkSoft,
            ),
          ),
        ),
      );
    }
    // Separate sections for the separate kinds of thing (Austin,
    // 2026-09-04): a fence post is not a species.
    final sections = [
      for (final realm in RecordRealm.values)
        (
          realm,
          [
            for (final g in groups)
              if (g.realm == realm) g,
          ],
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
          child: Kicker('On this map'),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final (realm, gs) in sections)
                if (gs.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                    child: Row(
                      children: [
                        Text(
                          realmTitles[realm]!.toUpperCase(),
                          style: TextStyle(
                            fontFamily: Type.slab,
                            fontWeight: FontWeight.w900,
                            fontSize: 17,
                            height: 0.9,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          '${gs.length}',
                          style: TextStyle(
                            fontFamily: Type.slab,
                            fontWeight: FontWeight.w900,
                            fontSize: 17,
                            color: Press.oxblood,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final g in gs) _speciesRow(g),
                ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _speciesRow(_SpeciesGroup g) {
    final open = g.key == _highlightKey;
    final dates =
        g.records.map((r) => r.observedAt).whereType<String>().toList()..sort();
    String day(String iso) => iso.length >= 10 ? iso.substring(0, 10) : iso;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () {
            setState(() => _highlightKey = open ? null : g.key);
            if (!open) _fitGroup(g.records);
          },
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: open ? Press.paperRaised : null,
              border: Border(
                bottom: BorderSide(color: Press.divider, width: 1),
                left: BorderSide(
                  color: open ? Press.oxblood : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Row(
              children: [
                _MarkSwatch(type: g.type, removal: g.removal),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    g.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: Type.serif,
                      fontSize: 15.5,
                      fontStyle: g.records.first.label != null
                          ? FontStyle.italic
                          : FontStyle.normal,
                      color: Press.ink,
                    ),
                  ),
                ),
                MonoLabel('${g.records.length}', size: 10, opacity: 0.7),
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Press.inkSoft,
                ),
              ],
            ),
          ),
        ),
        if (open)
          Container(
            color: Press.paperRaised,
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Press.paper,
                    border: Border.all(color: Press.borderInk, width: 1.5),
                  ),
                  child: Column(
                    children: [
                      FactRow(
                        'seen here',
                        '${g.records.length} time'
                            '${g.records.length == 1 ? '' : 's'}',
                      ),
                      FactRow('first', dates.isEmpty ? '—' : day(dates.first)),
                      FactRow(
                        'last',
                        dates.isEmpty ? '—' : day(dates.last),
                        last: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                for (final r in g.records)
                  if (r.id != null)
                    InkWell(
                      onTap: () {
                        setState(() {
                          _selectedId = r.id;
                          _closeSite();
                        });
                        _flyTo(r.lat, r.lng, zoom: activeImagery.maxZoom - 0.5);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            _RemovalRing(
                              removal: r.removal,
                              child: Diamond(
                                size: 8,
                                color: Color(markFor(r.type).argb),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                r.observedAt == null
                                    ? _cap(r.type)
                                    : '${day(r.observedAt!)} · ${r.type}',
                                style: TextStyle(
                                  fontFamily: Type.serif,
                                  fontSize: 13.5,
                                  color: Press.ink,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: Press.inkSoft,
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
      ],
    );
  }

  /// Inside setState.
  @override
  void _closeFeature() {
    _selectedFeatureId = null;
    _featureLoad = null;
    _featureLoadKey = null;
  }

  Widget _featurePanel(String featureId) {
    // Memoized on the feature and the layer set it was read against: this
    // build runs on every pan frame, and an inline Future.wait would
    // refire three queries per frame (audit 2026-09-04). The watch
    // replaces the set when any of its tables change, which is when the
    // panel re-reads.
    final key = (featureId, _layers);
    if (_featureLoadKey != key) {
      _featureLoadKey = key;
      _featureLoad = Future.wait([
        (widget.db.select(
          widget.db.features,
        )..where((f) => f.id.equals(featureId))).getSingleOrNull(),
        (widget.db.select(widget.db.featureConditionLogs)
              ..where((l) => l.featureId.equals(featureId))
              ..where((l) => l.deletedAt.isNull())
              ..orderBy([(l) => OrderingTerm.desc(l.observedAt)]))
            .get(),
        widget.db.select(widget.db.featureTypes).get(),
      ]);
    }
    return FutureBuilder(
      future: _featureLoad,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final f = data[0] as Feature?;
        final logs = data[1]! as List<FeatureConditionLog>;
        final types = data[2]! as List<FeatureType>;
        if (f == null || f.deletedAt != null) {
          return const Center(child: Text('This feature is gone.'));
        }
        final type = types.where((t) => t.id == f.featureTypeId).firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(_closeFeature),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Press.borderInk, width: 1.5),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.chevron_left, size: 18, color: Press.inkSoft),
                    const SizedBox(width: 4),
                    MonoLabel('SPECIES LIST', size: 9, spacing: 1.6),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  Kicker(
                    '${type?.label ?? 'Feature'} · '
                    '${type?.featureClass ?? 'natural'}',
                  ),
                  const SizedBox(height: 6),
                  Text(
                    f.name ?? type?.label ?? 'Feature',
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w900,
                      fontSize: 24,
                      color: Press.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  StatusPill(
                    (f.currentCondition ?? 'unknown').toUpperCase(),
                    color: conditionColor(f.currentCondition),
                    filled: true,
                  ),
                  if ((f.notes ?? '').isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      f.notes!,
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 15,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  MonoLabel('Condition history', size: 9, spacing: 1.8),
                  const SizedBox(height: 6),
                  if (logs.isEmpty)
                    Text(
                      'No condition history yet.',
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 14.5,
                        color: Press.inkSoft,
                      ),
                    )
                  else
                    for (final l in logs)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Diamond(
                              size: 10,
                              color: conditionColor(l.condition),
                              filled: true,
                            ),
                            const SizedBox(width: 8),
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
                                  fontSize: 14,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Press.oxblood,
                      ),
                      onPressed: () async {
                        final sure = await confirmDialog(
                          context,
                          title: 'DELETE THIS FEATURE?',
                          body:
                              'It leaves the map and its condition history '
                              'goes quiet. Nothing is erased from disk.',
                          confirmLabel: 'DELETE',
                        );
                        if (!sure || !mounted) return;
                        final now = nowUtcIso();
                        await (widget.db.update(
                          widget.db.features,
                        )..where((x) => x.id.equals(featureId))).write(
                          FeaturesCompanion(
                            deletedAt: Value(now),
                            updatedAt: Value(now),
                          ),
                        );
                        if (mounted) setState(_closeFeature);
                      },
                      child: const Text('DELETE FEATURE'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Inside setState.
  @override
  void _closeSite() {
    _selectedSiteId = null;
    _siteLoad = null;
    _siteLoadKey = null;
  }

  /// A clicked monitoring site (D-033): the method, the stake, when it was
  /// last visited and when it is next due, and every visit — each one a
  /// record, so a click opens it the way any mark does. Memoized on the
  /// site and the layer set like the feature panel; the watch on
  /// protocol_runs is what re-reads it after a visit is saved.
  Widget _sitePanel(String siteId) {
    final key = (siteId, _layers);
    if (_siteLoadKey != key) {
      _siteLoadKey = key;
      final svc = ProtocolService(widget.db);
      _siteLoad = () async {
        final site = await svc.siteById(siteId);
        final protocol = site == null
            ? null
            : await svc.protocolById(site.protocolId);
        final runs = await svc.runsFor(siteId);
        return <Object?>[site, protocol, runs];
      }();
    }
    return FutureBuilder(
      future: _siteLoad,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final site = data[0] as ProtocolSite?;
        final protocol = data[1] as Protocol?;
        final runs = data[2]! as List<ProtocolRun>;
        if (site == null || site.deletedAt != null) {
          return const Center(child: Text('This site is gone.'));
        }
        final retired = site.retiredOn != null;
        final last = runs.firstOrNull;
        String day(String iso) => iso.length >= 10 ? iso.substring(0, 10) : iso;
        final stake = [
          if (site.bearingDeg != null) '${site.bearingDeg!.round()}°',
          if (site.lengthM != null) '${site.lengthM!.round()} m',
          if (site.radiusM != null) 'r ${site.radiusM} m',
          if (site.marker != null) site.marker!.replaceAll('_', ' '),
        ].join(' · ');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Press.borderInk, width: 1.5),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(_closeSite),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.chevron_left,
                              size: 18,
                              color: Press.inkSoft,
                            ),
                            const SizedBox(width: 4),
                            MonoLabel('SPECIES LIST', size: 9, spacing: 1.6),
                          ],
                        ),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => _flyTo(
                      site.lat,
                      site.lng,
                      zoom: activeImagery.maxZoom - 0.5,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: MonoLabel('⌖ LOCATE', size: 9, spacing: 1.6),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  Kicker(
                    '${protocol?.name ?? 'Monitoring'} · '
                    '${protocol?.siteKind ?? 'site'}',
                  ),
                  if (protocol?.methodName != null) ...[
                    const SizedBox(height: 4),
                    MonoLabel(protocol!.methodName!, size: 9, opacity: 0.6),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    site.name,
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w900,
                      fontSize: 24,
                      color: Press.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  StatusPill(
                    retired ? 'NOT ASKING' : 'MONITORED',
                    color: retired ? Press.inkSoft : Press.sage,
                    filled: true,
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Press.paper,
                      border: Border.all(color: Press.borderInk, width: 1.5),
                    ),
                    child: Column(
                      children: [
                        FactRow('stake', stake.isEmpty ? '—' : stake),
                        FactRow(
                          'last visit',
                          last == null
                              ? 'never'
                              : day(last.startedAt) +
                                    (last.status == 'partial'
                                        ? ' · partial'
                                        : ''),
                        ),
                        FactRow('visits', '${runs.length}'),
                        FactRow(
                          'next due',
                          retired
                              ? 'not asking · since ${site.retiredOn}'
                              : (site.nextDueOn ?? '—'),
                          last: true,
                        ),
                      ],
                    ),
                  ),
                  if ((site.notes ?? '').isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      site.notes!,
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 15,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  MonoLabel('Visits', size: 9, spacing: 1.8),
                  const SizedBox(height: 6),
                  if (runs.isEmpty)
                    Text(
                      'No visits yet. The phone runs the method at the '
                      'stake; this desk reads them.',
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 14.5,
                        color: Press.inkSoft,
                      ),
                    )
                  else
                    for (final run in runs)
                      InkWell(
                        onTap: () => setState(() {
                          _selectedId = run.observationId;
                          _closeSite();
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            children: [
                              Diamond(
                                size: 8,
                                color: Color(markFor('survey').argb),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  day(run.startedAt) +
                                      (run.status == 'partial'
                                          ? ' · partial'
                                          : '') +
                                      (run.observerName == null
                                          ? ''
                                          : ' · ${run.observerName}'),
                                  style: TextStyle(
                                    fontFamily: Type.serif,
                                    fontSize: 13.5,
                                    color: Press.ink,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.chevron_right,
                                size: 16,
                                color: Press.inkSoft,
                              ),
                            ],
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// A clicked mark's record, with the way back to the species list.
  Widget _recordPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Press.borderInk, width: 1.5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _selectedId = null),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.chevron_left,
                          size: 18,
                          color: Press.inkSoft,
                        ),
                        const SizedBox(width: 4),
                        MonoLabel('SPECIES LIST', size: 9, spacing: 1.6),
                      ],
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: () {
                  final r = _layers?.records
                      .where((x) => x.id == _selectedId)
                      .firstOrNull;
                  if (r != null) {
                    _flyTo(r.lat, r.lng, zoom: activeImagery.maxZoom - 0.5);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: MonoLabel('⌖ LOCATE', size: 9, spacing: 1.6),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RecordDetailScreen(
            key: ValueKey(_selectedId),
            db: widget.db,
            obsId: _selectedId!,
            embedded: true,
          ),
        ),
      ],
    );
  }
}
