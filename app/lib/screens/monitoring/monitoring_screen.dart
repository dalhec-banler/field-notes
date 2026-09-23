import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../protocols/protocol_service.dart';
import '../../protocols/templates.dart';
import '../../theme/tokens.dart';
import '../../widgets/press.dart';
import 'new_site_sheet.dart';
import 'run_screen.dart';
import 'site_detail_screen.dart';

/// Grow › Monitoring: the due list, the sites, and the methods to start.
///
/// Four starters as cards, "More methods" behind one quiet row. The lay
/// name leads; the academic name is fine print.
class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({
    super.key,
    required this.db,
    required this.property,
    this.embedded = false,
  });

  final FieldNotesDb db;
  final Property property;
  final bool embedded;

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  ProtocolService get _svc => ProtocolService(widget.db);
  List<Protocol> _protocols = const [];
  List<ProtocolSite> _sites = const [];
  Set<String> _due = const {};
  bool _more = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MonitoringScreen old) {
    super.didUpdateWidget(old);
    if (old.property.id != widget.property.id) _load();
  }

  Future<void> _load() async {
    await _svc.ensureTemplates(widget.property.id);
    final protocols = await _svc.protocolsFor(widget.property.id);
    final sites = await _svc.sitesFor(widget.property.id, includeRetired: true);
    final due = (await _svc.dueSites(widget.property.id))
        .map((s) => s.id)
        .toSet();
    if (!mounted) return;
    setState(() {
      _protocols = protocols;
      _sites = sites;
      _due = due;
      _loading = false;
    });
  }

  Protocol? _protocolOf(ProtocolSite s) =>
      _protocols.where((p) => p.id == s.protocolId).firstOrNull;

  Future<void> _start(Protocol p) async {
    final template = templateFor(p.methodKey);
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(
          Metrics.gutter,
          18,
          Metrics.gutter,
          24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Kicker(p.name),
            if (p.methodName != null) ...[
              const SizedBox(height: 3),
              MonoLabel(p.methodName!, size: 9, opacity: 0.6),
            ],
            const SizedBox(height: 10),
            if (template != null) ...[
              Text(
                template.purpose,
                style: TextStyle(
                  fontFamily: Type.serif,
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 10),
              FactRow('Carry', template.carry),
              for (var i = 0; i < template.steps.length; i++)
                FactRow(
                  '${i + 1}',
                  template.steps[i],
                  last: i == template.steps.length - 1,
                ),
              if (p.seasonHint != null) ...[
                const SizedBox(height: 8),
                MonoLabel('When · ${p.seasonHint}', size: 9, opacity: 0.7),
              ],
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 56,
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('PUT THE FIRST STAKE ON THE MAP'),
              ),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    final site = await showNewSiteSheet(
      context,
      db: widget.db,
      property: widget.property,
      protocol: p,
    );
    if (site != null) await _load();
  }

  Future<void> _run(ProtocolSite s) async {
    final p = _protocolOf(s);
    if (p == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RunScreen(db: widget.db, protocol: p, site: s),
      ),
    );
    if (saved == true) await _load();
  }

  void _open(ProtocolSite s) {
    final p = _protocolOf(s);
    if (p == null) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) =>
                SiteDetailScreen(db: widget.db, protocol: p, site: s),
          ),
        )
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final starters = _protocols.where((p) => p.isStarter == 1).toList();
    final more = _protocols.where((p) => p.isStarter == 0).toList();
    final due = _sites.where((s) => _due.contains(s.id)).toList();
    final active = _sites.where((s) => s.retiredOn == null).toList();
    final retired = _sites.where((s) => s.retiredOn != null).toList();

    Widget siteTile(ProtocolSite s, {bool isDue = false}) {
      final p = _protocolOf(s);
      return ListTile(
        minTileHeight: 64,
        leading: CircleAvatar(
          backgroundColor: isDue ? Press.ochre.withValues(alpha: 0.15) : null,
          child: Icon(Icons.checklist_rtl, color: isDue ? Press.ochre : null),
        ),
        title: Text(s.name),
        subtitle: Text(
          [
            p?.name ?? '',
            if (s.retiredOn != null)
              'not asking'
            else if (s.nextDueOn != null)
              isDue ? 'DUE' : 'next ${s.nextDueOn}',
          ].join(' · '),
        ),
        trailing: s.retiredOn == null
            ? IconButton(
                icon: const Icon(Icons.play_arrow_outlined),
                tooltip: 'Same spot, same questions',
                onPressed: () => _run(s),
              )
            : null,
        onTap: () => _open(s),
      );
    }

    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Monitoring')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 140),
        children: [
          if (due.isNotEmpty) ...[
            _header('Due · ${due.length}'),
            for (final s in due) siteTile(s, isDue: true),
          ],
          if (active.isNotEmpty) ...[
            _header('Sites · ${active.length}'),
            for (final s in active)
              if (!_due.contains(s.id)) siteTile(s),
          ],
          if (_sites.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(32, 28, 32, 8),
              child: Text(
                'Monitoring is a saved spot and the same questions. Put a '
                'stake in, answer the questions, and come back next year. '
                'The change is the record.',
                textAlign: TextAlign.center,
              ),
            ),
          _header('Start a method'),
          for (final p in starters) _methodCard(p),
          if (!_more)
            TextButton(
              onPressed: () => setState(() => _more = true),
              child: const Text('MORE METHODS…'),
            )
          else ...[
            for (final p in more) _methodCard(p),
          ],
          if (retired.isNotEmpty) ...[
            _header('Not asking · ${retired.length}'),
            for (final s in retired) siteTile(s),
          ],
        ],
      ),
    );
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(Metrics.gutter, 18, Metrics.gutter, 6),
    child: Kicker(text),
  );

  Widget _methodCard(Protocol p) {
    final t = templateFor(p.methodKey);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Metrics.gutter, 0, Metrics.gutter, 10),
      child: InkWell(
        onTap: () => _start(p),
        child: InkCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.name,
                style: TextStyle(
                  fontFamily: Type.slab,
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  color: Press.ink,
                ),
              ),
              if (t != null) ...[
                const SizedBox(height: 4),
                Text(
                  t.purpose,
                  style: TextStyle(fontFamily: Type.serif, fontSize: 14.5),
                ),
              ],
              if (p.methodName != null) ...[
                const SizedBox(height: 6),
                MonoLabel(p.methodName!, size: 8.5, opacity: 0.55),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
