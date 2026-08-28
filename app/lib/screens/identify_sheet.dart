import 'dart:io';

import 'package:flutter/material.dart';

import '../db/database.dart';
import '../id/id_models.dart';
import '../id/identification_service.dart';
import '../id/llm_client.dart';
import '../id/plantnet_client.dart';
import '../theme/tokens.dart';
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
  required File photo,
}) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Press.paper,
    builder: (ctx) => _IdentifySheet(
      db: db,
      observation: observation,
      property: property,
      photo: photo,
    ),
  );
  return accepted ?? false;
}

class _IdentifySheet extends StatefulWidget {
  const _IdentifySheet({
    required this.db,
    required this.observation,
    required this.property,
    required this.photo,
  });

  final FieldNotesDb db;
  final Observation observation;
  final Property property;
  final File photo;

  @override
  State<_IdentifySheet> createState() => _IdentifySheetState();
}

class _IdentifySheetState extends State<_IdentifySheet> {
  late final _service = IdentificationService(widget.db);
  List<IdCandidate> _candidates = const [];
  String? _status;
  String? _error;
  bool _running = false;
  bool _configured = false;
  bool _loaded = false;
  String _organ = 'auto';

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
        photo: widget.photo,
        observation: widget.observation,
        property: widget.property,
        organ: _organ,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      if (!mounted) return;
      setState(() {
        _candidates = results;
        _status = results.isEmpty ? 'No confident match.' : null;
      });
    } on PlantNetException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on LlmException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Identification failed: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _accept(IdCandidate c) async {
    try {
      await _service.accept(
        candidate: c,
        observationId: widget.observation.id,
        propertyId: widget.property.id,
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
        padding: const EdgeInsets.fromLTRB(
            Metrics.gutter, 14, Metrics.gutter, 32),
        children: [
          const MonoLabel('What is it?', size: 10, spacing: 2),
          const SizedBox(height: 12),

          if (!_loaded)
            const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ))
          else if (!_configured) ...[
            const Text(
              'Photo identification needs a key from you first — Pl@ntNet, '
              'an AI provider, or both. Your account, your key, and nothing '
              'is sent until you ask.',
              style:
                  TextStyle(fontFamily: Type.serif, fontSize: 15.5, height: 1.45),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context, false);
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const SpeciesIdSettingsScreen()));
                },
                child: const Text('SET IT UP'),
              ),
            ),
          ] else ...[
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration:
                    BoxDecoration(border: Border.all(color: Press.ink, width: 1.5)),
                child: Image.file(widget.photo, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 12),
            if (_candidates.isEmpty && !_running) ...[
              const MonoLabel('What does the photo show?',
                  size: 9, spacing: 1.6),
              const SizedBox(height: 6),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final e in _organLabels.entries)
                    GestureDetector(
                      onTap: () => setState(() => _organ = e.key),
                      child: Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: _organ == e.key ? Press.ink : null,
                          border: Border.all(color: Press.ink, width: 1),
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
                              color:
                                  _organ == e.key ? Press.paper : Press.ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  icon: const Icon(Icons.search),
                  label: const Text('SUGGEST A SPECIES'),
                  onPressed: _run,
                ),
              ),
            ],
            if (_running) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  MonoLabel(_status ?? 'Looking…', size: 10, spacing: 1.2),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: const TextStyle(
                      fontFamily: Type.serif,
                      fontSize: 15,
                      color: Press.oxblood)),
            ],
            if (_candidates.isNotEmpty) ...[
              const SizedBox(height: 14),
              const MonoLabel('Suggestions · tap the one you agree with',
                  size: 9, spacing: 1.6),
              const SizedBox(height: 8),
              for (final c in _candidates) _candidateTile(c),
              const SizedBox(height: 14),
              const RailNote(
                color: Press.sage,
                body: 'Nothing has been written to this record. A suggestion '
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _accept(c),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Press.paperRaised,
            border: Border.all(color: Press.ink, width: 1.5),
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
                          Text(c.commonName!,
                              style: const TextStyle(
                                fontFamily: Type.slab,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                                color: Press.ink,
                              )),
                        TaxonName(c.name, size: 14),
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
                Text(c.reasoning!,
                    style: const TextStyle(
                        fontFamily: Type.serif, fontSize: 14.5, height: 1.4)),
              ],
              const SizedBox(height: 6),
              MonoLabel(
                  c.source == 'plantnet'
                      ? 'Pl@ntNet'
                      : c.source == 'llm_rerank'
                          ? 'weighed against this place'
                          : c.source,
                  size: 8.5,
                  opacity: 0.65),
            ],
          ),
        ),
      ),
    );
  }
}
