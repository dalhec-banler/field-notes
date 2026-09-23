import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../protocols/indicators.dart';
import '../../protocols/protocol_service.dart';
import '../../theme/tokens.dart';
import '../../widgets/confirm.dart';
import '../../widgets/press.dart';
import '../record_detail_screen.dart';
import 'run_screen.dart';

/// One site: what the method is, every visit with its headline numbers,
/// and the change between the last two said plainly.
class SiteDetailScreen extends StatefulWidget {
  const SiteDetailScreen({
    super.key,
    required this.db,
    required this.protocol,
    required this.site,
  });

  final FieldNotesDb db;
  final Protocol protocol;
  final ProtocolSite site;

  @override
  State<SiteDetailScreen> createState() => _SiteDetailScreenState();
}

class _SiteDetailScreenState extends State<SiteDetailScreen> {
  late ProtocolSite _site = widget.site;
  List<(ProtocolRun, List<Indicator>)> _runs = const [];
  bool _loading = true;

  ProtocolService get _svc => ProtocolService(widget.db);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final site = await (widget.db.select(
      widget.db.protocolSites,
    )..where((s) => s.id.equals(widget.site.id))).getSingleOrNull();
    final runs = await _svc.runsFor(widget.site.id);
    final out = <(ProtocolRun, List<Indicator>)>[];
    for (final r in runs) {
      out.add((r, await _svc.indicatorsFor(widget.protocol, site ?? _site, r)));
    }
    if (!mounted) return;
    setState(() {
      if (site != null) _site = site;
      _runs = out;
      _loading = false;
    });
  }

  Future<void> _startRun() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            RunScreen(db: widget.db, protocol: widget.protocol, site: _site),
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _retire() async {
    final retired = _site.retiredOn != null;
    final ok = await confirmDialog(
      context,
      title: retired ? 'ASK HERE AGAIN?' : 'STOP ASKING HERE?',
      body: retired
          ? 'The site comes back onto the due list.'
          : 'The site keeps its history and leaves the due list. You can '
                'bring it back.',
      confirmLabel: retired ? 'BRING BACK' : 'STOP ASKING',
    );
    if (!ok) return;
    await _svc.retireSite(_site.id, retired: !retired);
    await _load();
  }

  String _change() {
    if (_runs.length < 2) return '';
    final latest = _runs[0].$2;
    final before = _runs[1].$2;
    final parts = <String>[];
    for (final i in latest) {
      if (i.value == null) continue;
      final prev = before.where((p) => p.key == i.key).firstOrNull;
      if (prev?.value == null) continue;
      if ((i.value! - prev!.value!).abs() < 0.5) continue;
      parts.add('${i.label}: ${prev.display} → ${i.display}');
    }
    return parts.take(3).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.protocol;
    final s = _site;
    final change = _change();
    return Scaffold(
      appBar: AppBar(
        title: Text(s.name),
        actions: [
          IconButton(
            tooltip: s.retiredOn == null ? 'Stop asking here' : 'Bring back',
            icon: Icon(
              s.retiredOn == null
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
            ),
            onPressed: _retire,
          ),
        ],
      ),
      floatingActionButton: s.retiredOn == null
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.checklist),
              label: const Text('Same spot, same questions'),
              onPressed: _startRun,
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                12,
                Metrics.gutter,
                120,
              ),
              children: [
                Kicker(p.name),
                if (p.methodName != null) ...[
                  const SizedBox(height: 4),
                  MonoLabel(p.methodName!, size: 9, opacity: 0.6),
                ],
                const SizedBox(height: 10),
                FactRow(
                  'Site',
                  [
                    p.siteKind,
                    if (s.bearingDeg != null) '${s.bearingDeg!.round()}°',
                    if (s.lengthM != null) '${s.lengthM!.round()} m',
                    if (s.radiusM != null) 'r ${s.radiusM} m',
                    if (s.marker != null) s.marker!.replaceAll('_', ' '),
                  ].join(' · '),
                ),
                FactRow(
                  'Next due',
                  s.retiredOn != null
                      ? 'not asking · since ${s.retiredOn}'
                      : (s.nextDueOn ?? '—'),
                ),
                if (p.seasonHint != null) FactRow('When', p.seasonHint!),
                if (change.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  InkCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Kicker('Since last time'),
                        const SizedBox(height: 6),
                        Text(
                          change,
                          style: TextStyle(
                            fontFamily: Type.serif,
                            fontSize: 15,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Kicker('Visits · ${_runs.length}'),
                if (_runs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No visits yet. Stand at the stake and tap the button.',
                    ),
                  ),
                for (final (run, indicators) in _runs)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      run.startedAt.substring(0, 10) +
                          (run.status == 'partial' ? ' · partial' : ''),
                      style: TextStyle(
                        fontFamily: Type.slab,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      indicators
                          .where((i) => i.value != null)
                          .take(3)
                          .map((i) => '${i.label} ${i.display}')
                          .join(' · '),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RecordDetailScreen(
                          db: widget.db,
                          obsId: run.observationId,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
