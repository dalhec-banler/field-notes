part of '../export_workspace.dart';

/// Drawing the plate, composing the document, and saving it as PDF,
/// DOCX or HTML.
mixin _ExportRender on _ExportCore {
  void _scheduleRender({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: immediate ? 0 : 450), _render);
  }

  Future<void> _render() async {
    if (!mounted) return;
    final seq = ++_seq;
    // The base or the Settings imagery source may have changed.
    if (_fetchKey != '$_base:${activeImagery.id}') {
      _fetch = _buildFetcher();
    }
    setState(() => _rendering = true);
    try {
      final fresh = await loadPlateSubject(widget.db, widget.property);
      final (_, baseMaxZoom, baseLabel) = _baseSource;
      // Bigger sheets carry more pixels: the poster renders a plate a
      // print shop can hold at arm's length.
      final (maxW, maxH, over) = switch (_page) {
        PlatePage.letter => (1600.0, 1100.0, 1),
        PlatePage.tabloid => (2200.0, 1600.0, 2),
        PlatePage.poster => (3400.0, 2400.0, 2),
      };
      final r = await MapPlate(fetchTile: _fetch, maxZoom: baseMaxZoom).render(
        fresh,
        layers: _layers,
        species: _removalPlan ? null : _speciesSelection,
        removalPlan: _removalPlan,
        overzoom: over,
        maxWidth: maxW,
        maxHeight: maxH,
        attribution: 'Imagery: $baseLabel · Field Notes',
      );
      if (!mounted || seq != _seq) return; // a newer render superseded this
      setState(() {
        _subject = fresh;
        _plate = r;
        _note = r.tilesMissing > 0
            ? '${r.tilesMissing} imagery tiles unavailable'
            : null;
      });
    } catch (e) {
      if (mounted && seq == _seq) {
        setState(() => _note = 'Could not draw the plate: $e');
      }
    } finally {
      if (mounted && seq == _seq) setState(() => _rendering = false);
    }
  }

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  /// Records grouped by species (label, or type when unnamed), most-seen
  /// first. Palette position is the group's LIST index, so a species keeps
  /// its colour while others are toggled.
  List<(String, String, int, int)> get _recordGroups {
    final s = _subject;
    if (s == null) return const [];
    final counts = <String, (String, int)>{};
    for (final r in s.records) {
      final key = r.label ?? '__type:${r.type}';
      final label = r.label ?? _cap(r.type);
      final prev = counts[key];
      counts[key] = (label, (prev?.$2 ?? 0) + 1);
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.$2.compareTo(a.value.$2);
        return byCount != 0
            ? byCount
            : a.value.$1.toLowerCase().compareTo(b.value.$1.toLowerCase());
      });
    return [
      for (var i = 0; i < entries.length; i++)
        (
          entries[i].key,
          entries[i].value.$1,
          entries[i].value.$2,
          PlateInk.speciesWheel[i % PlateInk.speciesWheel.length],
        ),
    ];
  }

  /// A group with a species label is SPECIES; otherwise its type decides.
  RecordRealm _realmOf((String, String, int, int) g) =>
      g.$1.startsWith('__type:')
      ? realmOfType(g.$1.substring('__type:'.length))
      : RecordRealm.species;

  List<PlateSpecies>? get _speciesSelection {
    if (_speciesSel.isEmpty) return null;
    return [
      for (final g in _recordGroups)
        if (_speciesSel.contains(g.$1)) PlateSpecies(g.$1, g.$2, g.$4),
    ];
  }

  MapDocument? get _document {
    final p = _plate;
    final s = _subject;
    if (p == null || s == null) return null;
    return MapDocument(
      title: _title.text.trim().isEmpty
          ? widget.property.name
          : _title.text.trim(),
      plate: p,
      subject: s,
      layers: _layers,
      page: _page,
      species: _removalPlan ? null : _speciesSelection,
      removalPlan: _removalPlan,
      preparedFor: _preparedFor.text,
      notes: _notes.text,
    );
  }

  String get _baseName {
    final t = (_title.text.trim().isEmpty ? widget.property.name : _title.text)
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final d = DateTime.now();
    final kind = _removalPlan ? 'removal-plan' : 'map';
    return '$t-$kind-${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _save(String ext, Future<Uint8List> Function() bytes) async {
    if (_saving) return;
    final loc = await getSaveLocation(
      suggestedName: '$_baseName.$ext',
      acceptedTypeGroups: [
        XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    if (loc == null) return;
    setState(() => _saving = true);
    try {
      final data = await bytes();
      await File(loc.path).writeAsBytes(data, flush: true);
      if (mounted) setState(() => _note = 'Saved ${loc.path}');
    } catch (e) {
      if (mounted) setState(() => _note = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The page as pixels — what PNG means now: the composed document, not
  /// a bare map with nothing under it (audit finding 5).
  Future<Uint8List> _pagePng() async {
    final boundary =
        _pageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await boundary.toImage(pixelRatio: 2.5);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  Future<void> _saveAs(String ext) async {
    final d = _document;
    if (d == null) return;
    switch (ext) {
      case 'pdf':
        await _save('pdf', () async {
          final theme = await MapReport.loadTheme();
          return d.removalPlan
              ? RemovalPlan.build(d, theme: theme)
              : MapReport.build(d, theme: theme);
        });
      case 'png':
        await _save('png', _pagePng);
      case 'docx':
        await _save('docx', () async => MapDocx.build(d));
      case 'html':
        await _save('html', () async {
          final html = MapHtml.build(
            d.subject,
            layers: d.layers,
            species: d.species,
            title: d.title,
            dateLine: d.dateLine,
          );
          // utf8, not codeUnits: an em dash or a species name with an
          // accent must survive the trip to disk (audit 2026-09-04).
          return Uint8List.fromList(utf8.encode(html));
        });
    }
  }
}
