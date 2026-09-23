import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../db/database.dart';
import '../../main.dart' show locationHub;
import '../../protocols/field_defs.dart';
import '../../protocols/protocol_service.dart';
import '../../services/media_store.dart';
import '../../theme/tokens.dart';
import '../../widgets/press.dart';
import '../../widgets/species_field.dart';

/// Same spot, same questions.
///
/// One sample per page for repeated groups ("Frame 2 of 5"), the once-per-
/// visit questions on a page of their own, a big NEXT at the thumb. Class
/// answers are chips with the lay word on them and the academic class in
/// fine print. Last time's answer sits in ghost text under each question.
/// Required answers dim NEXT; they never block a save — a run cut short
/// saves as partial and the site stays due.
class RunScreen extends StatefulWidget {
  const RunScreen({
    super.key,
    required this.db,
    required this.protocol,
    required this.site,
  });

  final FieldNotesDb db;
  final Protocol protocol;
  final ProtocolSite site;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  late final List<FieldDef> _fields = parseFields(widget.protocol.fieldsJson);
  final Map<String, dynamic> _values = {};
  Map<String, dynamic> _last = const {};
  late final DateTime _startedAt = DateTime.now();
  late final List<_Page> _pages = _buildPages();
  int _page = 0;
  bool _saving = false;
  final List<(String, XFile)> _photos = []; // field key → picked photo
  Timer? _clock;
  int _elapsed = 0;

  bool get _timed => widget.protocol.methodKey == 'bird_listen';

  @override
  void initState() {
    super.initState();
    ProtocolService(widget.db).lastRun(widget.site.id).then((run) {
      if (run != null && mounted) {
        setState(() => _last = ProtocolService.valuesOf(run));
      }
    });
    if (_timed) {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed++);
      });
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  /// Pages: each repeated sample is a page; every non-group field shares
  /// one closing page. An open group ("as many as you see") is one page
  /// with an add-another control.
  List<_Page> _buildPages() {
    final pages = <_Page>[];
    final single = <FieldDef>[];
    for (final f in _fields) {
      if (f.type == FieldType.group) {
        if (f.repeat != null) {
          for (var i = 0; i < f.repeat!; i++) {
            pages.add(_Page.sample(f, i));
          }
        } else {
          pages.add(_Page.openGroup(f));
        }
      } else {
        single.add(f);
      }
    }
    if (single.isNotEmpty) pages.add(_Page.single(single));
    return pages;
  }

  Map<String, dynamic> _sample(FieldDef group, int index) {
    final list = (_values[group.key] ??= <Map<String, dynamic>>[]) as List;
    while (list.length <= index) {
      list.add(<String, dynamic>{});
    }
    return list[index] as Map<String, dynamic>;
  }

  Object? _lastFor(FieldDef group, int index, String key) {
    final list = _last[group.key];
    if (list is List && index < list.length && list[index] is Map) {
      return (list[index] as Map)[key];
    }
    return null;
  }

  bool _pageComplete(_Page p) {
    switch (p.kind) {
      case _PageKind.sample:
        final s = _sample(p.group!, p.index!);
        return p.group!.requiredFields.every((f) => !_isEmpty(s[f.key]));
      case _PageKind.openGroup:
        return true;
      case _PageKind.single:
        return p.fields
            .where((f) => f.required)
            .every((f) => !_isEmpty(_values[f.key]));
    }
  }

  static bool _isEmpty(Object? v) =>
      v == null || (v is String && v.isEmpty) || (v is List && v.isEmpty);

  Future<void> _finish() async {
    if (_saving) return;
    final missing = ProtocolService.missingRequired(_fields, _values);
    var status = 'complete';
    if (missing.isNotEmpty) {
      final keep = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('NOT QUITE DONE'),
          content: Text(
            '${missing.take(3).join('. ')}.\n\nKeep it as a partial? You '
            'can finish next time you are here.',
            style: TextStyle(fontFamily: Type.serif, fontSize: 15, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('KEEP GOING'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('SAVE PARTIAL'),
            ),
          ],
        ),
      );
      if (keep != true) return;
      status = 'partial';
    }
    setState(() => _saving = true);
    final fix = locationHub.fresh();
    final svc = ProtocolService(widget.db);
    final run = await svc.saveRun(
      protocol: widget.protocol,
      site: widget.site,
      values: _values,
      actualLat: fix?.latitude,
      actualLng: fix?.longitude,
      gpsAccuracyM: fix?.accuracy,
      startedAt: _startedAt,
      endedAt: DateTime.now(),
      status: status,
    );
    // Photos ride the observation, like every record's.
    final store = MediaStore(widget.db);
    for (final (key, file) in _photos) {
      try {
        final media = await store.savePhoto(
          await file.readAsBytes(),
          propertyId: widget.site.propertyId,
          createdBy: 'local',
          lat: fix?.latitude,
          lng: fix?.longitude,
        );
        await store.linkTo(
          media.id,
          propertyId: widget.site.propertyId,
          entityType: 'observation',
          entityId: run.observationId,
          role: _photos.first.$1 == key ? 'primary' : 'attachment',
        );
        _values[key] = media.id;
      } catch (_) {
        // A photo that fails to save never loses the answers.
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          status == 'partial'
              ? 'Saved as partial · the site stays due'
              : 'Saved · ${widget.site.name}',
        ),
      ),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final page = _pages[_page];
    final last = _page == _pages.length - 1;
    final complete = _pageComplete(page);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.site.name),
        actions: [
          if (_timed)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: MonoLabel(
                  '${(_elapsed ~/ 60).toString().padLeft(2, '0')}:'
                  '${(_elapsed % 60).toString().padLeft(2, '0')}'
                  '${_elapsed >= 600 ? ' · TIME' : ''}',
                  size: 12,
                  color: _elapsed >= 600 ? Press.oxblood : Press.ink,
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(
              value: (_page + 1) / _pages.length,
              minHeight: 3,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  Metrics.gutter,
                  16,
                  Metrics.gutter,
                  24,
                ),
                children: [
                  Kicker(_pageTitle(page)),
                  if (page.group?.hint != null) ...[
                    const SizedBox(height: 4),
                    MonoLabel(page.group!.hint!, size: 9, opacity: 0.6),
                  ],
                  const SizedBox(height: 12),
                  ..._pageBody(page),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                6,
                Metrics.gutter,
                12,
              ),
              child: Row(
                children: [
                  if (_page > 0)
                    SizedBox(
                      height: 56,
                      child: TextButton(
                        onPressed: () => setState(() => _page--),
                        child: const Text('BACK'),
                      ),
                    ),
                  const Spacer(),
                  SizedBox(
                    height: 56,
                    child: TextButton(
                      onPressed: _saving ? null : _finish,
                      child: const Text('FINISH'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (!last)
                    SizedBox(
                      height: 56,
                      child: FilledButton(
                        onPressed: complete
                            ? () => setState(() => _page++)
                            : null,
                        child: const Text('NEXT'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _pageTitle(_Page p) => switch (p.kind) {
    _PageKind.sample =>
      p.group!.fixed.length > p.index!
          ? '${p.group!.label} · ${p.group!.fixed[p.index!]}'
          : '${p.group!.label} ${p.index! + 1} of ${p.group!.repeat}',
    _PageKind.openGroup => p.group!.label,
    _PageKind.single => 'This visit',
  };

  List<Widget> _pageBody(_Page p) {
    switch (p.kind) {
      case _PageKind.sample:
        final s = _sample(p.group!, p.index!);
        return [
          for (final f in p.group!.fields)
            _field(
              f,
              value: s[f.key],
              last: _lastFor(p.group!, p.index!, f.key),
              onChanged: (v) => setState(() => s[f.key] = v),
            ),
        ];
      case _PageKind.openGroup:
        final list =
            (_values[p.group!.key] ??= <Map<String, dynamic>>[]) as List;
        return [
          for (var i = 0; i < list.length; i++) ...[
            MonoLabel('${p.group!.label} ${i + 1}', size: 9.5, opacity: 0.7),
            for (final f in p.group!.fields)
              _field(
                f,
                value: (list[i] as Map)[f.key],
                last: null,
                onChanged: (v) => setState(() => (list[i] as Map)[f.key] = v),
              ),
            const Divider(),
          ],
          OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: Text('ANOTHER ${p.group!.label.toUpperCase()}'),
            onPressed: () => setState(() => list.add(<String, dynamic>{})),
          ),
        ];
      case _PageKind.single:
        return [
          for (final f in p.fields)
            _field(
              f,
              value: _values[f.key],
              last: _last[f.key],
              onChanged: (v) => setState(() => _values[f.key] = v),
            ),
        ];
    }
  }

  Widget _field(
    FieldDef f, {
    required Object? value,
    required Object? last,
    required ValueChanged<Object?> onChanged,
  }) {
    final body = switch (f.type) {
      FieldType.class_ => _classChips(f, value, onChanged),
      FieldType.choice => _choiceChips(f, value, onChanged),
      FieldType.int_ || FieldType.real => _number(f, value, onChanged),
      FieldType.bool_ => _toggle(f, value, onChanged),
      FieldType.text => _text(f, value, onChanged),
      FieldType.taxa => _taxa(f, value, onChanged),
      FieldType.countByTaxon => _countByTaxon(f, value, onChanged),
      FieldType.photo => _photo(f, value),
      FieldType.group => const SizedBox.shrink(),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  f.label,
                  style: TextStyle(
                    fontFamily: Type.slab,
                    fontWeight: FontWeight.w700,
                    fontSize: 15.5,
                    color: Press.ink,
                  ),
                ),
              ),
              if (last != null)
                MonoLabel(
                  'last time: ${_lastLabel(f, last)}',
                  size: 9,
                  opacity: 0.55,
                ),
            ],
          ),
          if (f.hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: MonoLabel(f.hint!, size: 9, opacity: 0.6),
            ),
          const SizedBox(height: 6),
          body,
        ],
      ),
    );
  }

  String _lastLabel(FieldDef f, Object? last) {
    if (f.type == FieldType.class_) {
      if ('$last' == absentCode) return 'none';
      return scales[f.scale]?.byCode(last)?.label ?? '$last';
    }
    if (f.type == FieldType.choice) {
      for (final c in f.choices) {
        if (c.$1 == '$last') return c.$2;
      }
    }
    if (last is List) return '${last.length}';
    return '$last';
  }

  Widget _classChips(
    FieldDef f,
    Object? value,
    ValueChanged<Object?> onChanged,
  ) {
    final scale = scales[f.scale];
    if (scale == null) return const SizedBox.shrink();
    final isCover = scale.unit == 'pct_cover_midpoint';
    final steps = [
      if (isCover) const ClassStep(absentCode, 'None', 0),
      ...scale.classes,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in steps)
              ChoiceChip(
                label: Text(s.label),
                selected: '$value' == s.code && value != null,
                onSelected: (_) => onChanged(s.code),
              ),
          ],
        ),
        const SizedBox(height: 4),
        MonoLabel(
          value == null
              ? scale.methodName
              : '${scale.methodName} · ${'$value' == absentCode ? '0' : value}'
                    '${scale.byCode(value)?.detail != null ? ' · ${scale.byCode(value)!.detail}' : ''}',
          size: 8.5,
          opacity: 0.5,
        ),
      ],
    );
  }

  Widget _choiceChips(
    FieldDef f,
    Object? value,
    ValueChanged<Object?> onChanged,
  ) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final c in f.choices)
        ChoiceChip(
          label: Text(c.$2),
          selected: '$value' == c.$1 && value != null,
          onSelected: (_) => onChanged(c.$1),
        ),
    ],
  );

  Widget _number(FieldDef f, Object? value, ValueChanged<Object?> onChanged) {
    return TextFormField(
      initialValue: value?.toString() ?? '',
      keyboardType: TextInputType.numberWithOptions(
        decimal: f.type == FieldType.real,
      ),
      decoration: InputDecoration(
        suffixText: f.unit,
        hintText: [
          if (f.min != null) 'from ${f.min}',
          if (f.max != null) 'to ${f.max}',
        ].join(' '),
        isDense: true,
      ),
      onChanged: (t) {
        final n = f.type == FieldType.real
            ? double.tryParse(t)
            : int.tryParse(t);
        onChanged(n);
      },
    );
  }

  Widget _toggle(FieldDef f, Object? value, ValueChanged<Object?> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(value == true ? 'Yes' : 'No'),
        value: value == true,
        onChanged: onChanged,
      );

  Widget _text(FieldDef f, Object? value, ValueChanged<Object?> onChanged) =>
      TextFormField(
        initialValue: value?.toString() ?? '',
        maxLines: 3,
        minLines: 1,
        onChanged: onChanged,
      );

  Widget _taxa(FieldDef f, Object? value, ValueChanged<Object?> onChanged) {
    final ids = value is List ? value.cast<String>() : <String>[];
    final max = f.maxCount ?? 99;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final id in ids)
          _TaxonRow(
            db: widget.db,
            taxonId: id,
            onRemove: () => onChanged([...ids]..remove(id)),
          ),
        if (ids.length < max)
          SpeciesField(
            key: ValueKey('${f.key}-${ids.length}'),
            db: widget.db,
            label: ids.isEmpty ? 'Pick a plant' : 'Add another',
            onSelected: (t) {
              if (t != null && !ids.contains(t.id)) onChanged([...ids, t.id]);
            },
          ),
      ],
    );
  }

  Widget _countByTaxon(
    FieldDef f,
    Object? value,
    ValueChanged<Object?> onChanged,
  ) {
    final rows = value is List
        ? value.map((e) => Map<String, dynamic>.from(e as Map)).toList()
        : <Map<String, dynamic>>[];
    void update() => onChanged(rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: _TaxonRow(
                    db: widget.db,
                    taxonId: '${r['taxon_id']}',
                    trailing: f.by == null
                        ? null
                        : [
                            for (final c in f.byChoices)
                              if (c.$1 == r['by']) c.$2,
                          ].firstOrNull,
                    onRemove: () {
                      rows.remove(r);
                      update();
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () {
                    r['count'] = ((r['count'] as int?) ?? 0) - 1;
                    if ((r['count'] as int) <= 0) rows.remove(r);
                    update();
                  },
                ),
                SizedBox(
                  width: 28,
                  child: Text(
                    '${r['count'] ?? 0}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: Type.mono,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () {
                    r['count'] = ((r['count'] as int?) ?? 0) + 1;
                    update();
                  },
                ),
              ],
            ),
          ),
        _CountAdder(
          key: ValueKey('${f.key}-${rows.length}'),
          db: widget.db,
          byChoices: f.byChoices,
          onAdd: (taxon, by) {
            final existing = rows
                .where((r) => r['taxon_id'] == taxon.id && r['by'] == by)
                .firstOrNull;
            if (existing != null) {
              existing['count'] = ((existing['count'] as int?) ?? 0) + 1;
            } else {
              rows.add({
                'taxon_id': taxon.id,
                'count': 1,
                'by': ?by,
              });
            }
            update();
          },
        ),
      ],
    );
  }

  Widget _photo(FieldDef f, Object? value) {
    final picked = _photos.where((p) => p.$1 == f.key).firstOrNull;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: Icon(
              picked == null ? Icons.photo_camera_outlined : Icons.check,
            ),
            label: Text(
              picked == null ? 'TAKE THE PHOTO' : 'PHOTO TAKEN · RETAKE',
            ),
            onPressed: () async {
              final file = await ImagePicker().pickImage(
                source: ImageSource.camera,
                imageQuality: 92,
              );
              if (file == null || !mounted) return;
              setState(() {
                _photos.removeWhere((p) => p.$1 == f.key);
                _photos.add((f.key, file));
              });
            },
          ),
        ),
      ],
    );
  }
}

enum _PageKind { sample, openGroup, single }

class _Page {
  const _Page._(this.kind, {this.group, this.index, this.fields = const []});
  factory _Page.sample(FieldDef group, int index) =>
      _Page._(_PageKind.sample, group: group, index: index);
  factory _Page.openGroup(FieldDef group) =>
      _Page._(_PageKind.openGroup, group: group);
  factory _Page.single(List<FieldDef> fields) =>
      _Page._(_PageKind.single, fields: fields);

  final _PageKind kind;
  final FieldDef? group;
  final int? index;
  final List<FieldDef> fields;
}

/// A picked species, named, with a remove control.
class _TaxonRow extends StatelessWidget {
  const _TaxonRow({
    required this.db,
    required this.taxonId,
    required this.onRemove,
    this.trailing,
  });

  final FieldNotesDb db;
  final String taxonId;
  final VoidCallback onRemove;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TaxaData?>(
      future: (db.select(
        db.taxa,
      )..where((t) => t.id.equals(taxonId))).getSingleOrNull(),
      builder: (context, snap) {
        final t = snap.data;
        return Row(
          children: [
            Expanded(
              child: Text(
                t == null
                    ? '…'
                    : '${t.commonName ?? t.scientificName}'
                          '${trailing != null ? ' · $trailing' : ''}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: Type.serif, fontSize: 15),
              ),
            ),
            IconButton(
              iconSize: 18,
              icon: const Icon(Icons.close),
              onPressed: onRemove,
            ),
          ],
        );
      },
    );
  }
}

/// Species picker plus the "by" chip (size class, distance band) that
/// adds one counted row.
class _CountAdder extends StatefulWidget {
  const _CountAdder({
    super.key,
    required this.db,
    required this.byChoices,
    required this.onAdd,
  });

  final FieldNotesDb db;
  final List<(String, String)> byChoices;
  final void Function(TaxaData taxon, String? by) onAdd;

  @override
  State<_CountAdder> createState() => _CountAdderState();
}

class _CountAdderState extends State<_CountAdder> {
  String? _by;

  @override
  void initState() {
    super.initState();
    if (widget.byChoices.isNotEmpty) _by = widget.byChoices.first.$1;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.byChoices.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final c in widget.byChoices)
                ChoiceChip(
                  label: Text(c.$2),
                  selected: _by == c.$1,
                  onSelected: (_) => setState(() => _by = c.$1),
                ),
            ],
          ),
        const SizedBox(height: 6),
        SpeciesField(
          db: widget.db,
          label: 'Tap a species to count one',
          onSelected: (t) {
            if (t != null) widget.onAdd(t, _by);
          },
        ),
      ],
    );
  }
}
