import 'dart:io';

import 'package:flutter/material.dart';

import '../db/database.dart';
import '../id/id_models.dart';
import '../id/identification_service.dart';
import '../id/llm_client.dart';
import '../id/plantnet_client.dart';
import '../theme/tokens.dart';
import '../widgets/nativity_chip.dart';
import '../widgets/press.dart';
import 'species_id_settings_screen.dart';

/// Ask for an identification, read the reasoning, decide.
///
/// Nothing here writes a species onto the record except the user tapping a
/// candidate — that is the whole design (spec §5).
Future<bool> showIdentifySheet(
  BuildContext context, {
  required FieldNotesDb db,
  required Observation observation,
  required Property property,
  required List<File> photos,
  bool persist = true,
  Future<void> Function(IdCandidate)? onChoose,
  void Function(List<IdCandidate>)? onCandidates,
}) async {
  // Every caller gates on having photos, but the service and the preview
  // both assume `photos.first` exists — keep the invariant here too.
  if (photos.isEmpty) return false;
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Press.paper,
    builder: (ctx) => _IdentifySheet(
      db: db,
      observation: observation,
      property: property,
      photos: photos,
      persist: persist,
      onChoose: onChoose,
      onCandidates: onCandidates,
    ),
  );
  return accepted ?? false;
}

class _IdentifySheet extends StatefulWidget {
  _IdentifySheet({
    required this.db,
    required this.observation,
    required this.property,
    required this.photos,
    this.persist = true,
    this.onChoose,
    this.onCandidates,
  });

  final FieldNotesDb db;
  final Observation observation;
  final Property property;
  final List<File> photos;
  final bool persist;
  final Future<void> Function(IdCandidate)? onChoose;
  final void Function(List<IdCandidate>)? onCandidates;

  @override
  State<_IdentifySheet> createState() => _IdentifySheetState();
}

class _IdentifySheetState extends State<_IdentifySheet> {
  late final _service = IdentificationService(widget.db);
  List<IdCandidate> _candidates = [];
  Map<String, String> _nativity = const {};
  String? _status;
  String? _error;
  bool _running = false;
  bool _configured = false;
  bool _loaded = false;
  String _organ = 'auto';

  /// Pl@ntNet reads at most five images; with more, the user picks which.
  late final List<int> _picked = [
    for (var i = 0; i < widget.photos.length && i < 5; i++) i,
  ];

  static const _organLabels = {
    'auto': 'Whole plant',
    'leaf': 'Leaf',
    'flower': 'Flower',
    'fruit': 'Fruit',
    'bark': 'Bark',
    'habit': 'Habit',
  };

  @override
  void initState() {
    super.initState();
    _service.isConfigured.then((v) {
      if (!mounted) return;
      setState(() {
        _configured = v;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _status = 'Looking…';
    });
    try {
      final results = await _service.identify(
        photos: [for (final i in _picked) widget.photos[i]],
        observation: widget.observation,
        property: widget.property,
        organ: _organ,
        persist: widget.persist,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      if (!mounted) return;
      widget.onCandidates?.call(results);
      // Nativity for candidates already in the library — the chip that says
      // whether you're about to celebrate or pull it.
      final ids = [
        for (final c in results)
          if (c.taxonId != null) c.taxonId!,
      ];
      final nat = <String, String>{};
      if (ids.isNotEmpty) {
        final taxa = await (widget.db.select(
          widget.db.taxa,
        )..where((t) => t.id.isIn(ids))).get();
        for (final t in taxa) {
          if (t.nativity != null) nat[t.id] = t.nativity!;
        }
      }
      if (!mounted) return;
      setState(() {
        _nativity = nat;
        _candidates = results;
        _status = results.isEmpty ? 'No confident match.' : null;
      });
    } on PlantNetException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on LlmException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      final offline = e is SocketException || '$e'.contains('SocketException');
      if (mounted) {
        setState(
          () => _error = offline
              ? 'No signal here — identification needs it. Your photos and '
                    'record are safe on this phone; ask again from the '
                    'record when you have coverage.'
              : 'Identification failed: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _accept(IdCandidate c) async {
    try {
      if (widget.onChoose != null) {
        await widget.onChoose!(c);
        if (mounted) Navigator.pop(context, true);
        return;
      }
      await _service.accept(
        candidate: c,
        observationId: widget.observation.id,
        propertyId: widget.property.id,
        runId: _service.lastRunId,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save that: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(Metrics.gutter, 14, Metrics.gutter, 32),
        children: [
          MonoLabel('What is it?', size: 10, spacing: 2),
          SizedBox(height: 12),

          if (!_loaded)
            Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (!_configured) ...[
            Text(
              'Photo identification needs a key from you first — Pl@ntNet, '
              'an AI provider, or both. Your account, your key, and nothing '
              'is sent until you ask.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 15.5,
                height: 1.45,
              ),
            ),
            SizedBox(height: 14),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context, false);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SpeciesIdSettingsScreen(),
                    ),
                  );
                },
                child: Text('SET IT UP'),
              ),
            ),
          ] else ...[
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Press.borderInk, width: 1.5),
                ),
                child: Image.file(
                  widget.photos[_picked.isEmpty ? 0 : _picked.first],
                  fit: BoxFit.cover,
                ),
              ),
            ),
            SizedBox(height: 12),
            if (_candidates.isEmpty && !_running) ...[
              if (widget.photos.length > 1) ...[
                MonoLabel(
                  widget.photos.length > 5
                      ? 'Pl@ntNet reads five images — tap to choose which '
                            '(${_picked.length} of 5 chosen)'
                      : 'Tap to choose which photos go up '
                            '(${_picked.length} of ${widget.photos.length})',
                  size: 9,
                  spacing: 1.6,
                ),
                SizedBox(height: 6),
                SizedBox(
                  height: 64,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < widget.photos.length; i++)
                        GestureDetector(
                          onTap: () => setState(() {
                            if (_picked.contains(i)) {
                              if (_picked.length > 1) _picked.remove(i);
                            } else if (_picked.length < 5) {
                              _picked.add(i);
                            }
                          }),
                          child: Container(
                            width: 60,
                            margin: EdgeInsets.only(right: 6),
                            foregroundDecoration: _picked.contains(i)
                                ? null
                                : BoxDecoration(
                                    color: Press.paperRaised.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: _picked.contains(i)
                                    ? Press.oxblood
                                    : Press.borderInk,
                                width: _picked.contains(i) ? 2 : 1,
                              ),
                              image: DecorationImage(
                                image: FileImage(widget.photos[i]),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: 12),
              ],
              MonoLabel('What does the photo show?', size: 9, spacing: 1.6),
              SizedBox(height: 6),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final e in _organLabels.entries)
                    GestureDetector(
                      onTap: () => setState(() => _organ = e.key),
                      child: Container(
                        height: 48,
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: _organ == e.key ? Press.ink : null,
                          border: Border.all(color: Press.borderInk, width: 1),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            e.value.toUpperCase(),
                            style: TextStyle(
                              fontFamily: Type.mono,
                              fontSize: 9.5,
                              letterSpacing: 1.4,
                              color: _organ == e.key ? Press.paper : Press.ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: 14),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  icon: Icon(Icons.search),
                  label: Text('SUGGEST A SPECIES'),
                  onPressed: _run,
                ),
              ),
            ],
            if (_running) ...[
              SizedBox(height: 10),
              Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  MonoLabel(_status ?? 'Looking…', size: 10, spacing: 1.2),
                ],
              ),
            ],
            if (_error != null) ...[
              SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  fontFamily: Type.serif,
                  fontSize: 15,
                  color: Press.oxblood,
                ),
              ),
            ],
            if (_candidates.isNotEmpty) ...[
              SizedBox(height: 14),
              MonoLabel(
                'Suggestions · tap the one you agree with',
                size: 9,
                spacing: 1.6,
              ),
              const SizedBox(height: 8),
              for (final c in _candidates) _candidateTile(c),
              const SizedBox(height: 14),
              RailNote(
                color: Press.sage,
                body:
                    'Nothing has been written to this record. A suggestion '
                    'only becomes the species when you tap it.',
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: _running ? null : _run,
                  child: const Text('ASK AGAIN'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _candidateTile(IdCandidate c) {
    final pct = c.score == null
        ? null
        : '${(c.score! * 100).clamp(0, 100).toStringAsFixed(0)}%';
    final nativity = c.taxonId == null ? null : _nativity[c.taxonId];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _accept(c),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Press.paperRaised,
            border: Border.all(color: Press.borderInk, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (c.commonName != null)
                          Text(
                            c.commonName!,
                            style: TextStyle(
                              fontFamily: Type.slab,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: Press.ink,
                            ),
                          ),
                        TaxonName(c.name, size: 14),
                        if (nativity != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: NativityChip(nativity),
                          ),
                      ],
                    ),
                  ),
                  if (pct != null) ...[
                    const SizedBox(width: 8),
                    BigNumber(pct, size: 15),
                  ],
                ],
              ),
              if (c.reasoning != null) ...[
                const SizedBox(height: 8),
                Text(
                  c.reasoning!,
                  style: TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 14.5,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              MonoLabel(
                c.source == 'plantnet'
                    ? 'Pl@ntNet'
                    : c.source == 'llm_rerank'
                    ? 'weighed against this place'
                    : c.source,
                size: 8.5,
                opacity: 0.65,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
