import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../protocols/indicators.dart';
import '../../theme/tokens.dart';
import '../../widgets/press.dart';

/// What one visit added up to: the method and site on top, the headline
/// numbers as stat cells, the academic name in fine print.
class RunSummaryCard extends StatelessWidget {
  const RunSummaryCard({
    super.key,
    required this.protocol,
    required this.site,
    required this.run,
    required this.indicators,
    this.onOpenSite,
  });

  final Protocol protocol;
  final ProtocolSite site;
  final ProtocolRun run;
  final List<Indicator> indicators;
  final VoidCallback? onOpenSite;

  @override
  Widget build(BuildContext context) {
    final shown = indicators.where((i) => i.value != null).take(4).toList();
    return InkCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Kicker('Monitoring · ${protocol.name}')),
              if (run.status == 'partial')
                StatusPill('PARTIAL', color: Press.ochre),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            site.name,
            style: TextStyle(
              fontFamily: Type.slab,
              fontWeight: FontWeight.w700,
              fontSize: 17,
              color: Press.ink,
            ),
          ),
          if (protocol.methodName != null) ...[
            const SizedBox(height: 2),
            MonoLabel(protocol.methodName!, size: 9, opacity: 0.6),
          ],
          if (shown.isNotEmpty) ...[
            const SizedBox(height: 12),
            StatCells(
              cells: [for (final i in shown) (i.label, i.display, null)],
            ),
          ],
          for (final i in indicators)
            if (i.detail != null && i.value != null && i.key.contains('by_'))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: MonoLabel(i.detail!, size: 9, opacity: 0.7),
              ),
          if (onOpenSite != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onOpenSite,
                child: const Text('SITE HISTORY'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
