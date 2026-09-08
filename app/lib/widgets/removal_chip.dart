import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Removal state at a glance (D-027): oxblood while it's flagged and still
/// standing, ink once it's gone. Shown wherever the record is — removal is
/// work on the ledger, as visible as a planting.
class RemovalChip extends StatelessWidget {
  const RemovalChip(this.status, {this.removedOn, super.key});

  final String? status;
  final String? removedOn;

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) return const SizedBox.shrink();
    final flagged = s == 'flagged';
    final label = flagged
        ? 'FLAGGED FOR REMOVAL'
        : 'REMOVED${removedOn != null ? ' · $removedOn' : ''}';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: flagged ? Press.oxblood : null,
        border: Border.all(
          color: flagged ? Press.oxblood : Press.ink,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: Type.mono,
          fontSize: 8.5,
          letterSpacing: 1.2,
          color: flagged ? Press.paper : Press.ink,
        ),
      ),
    );
  }
}
