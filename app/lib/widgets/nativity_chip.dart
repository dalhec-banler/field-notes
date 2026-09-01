import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Nativity at a glance: sage for native, ochre for introduced, oxblood
/// for invasive. Shown wherever a species is offered or displayed — the
/// difference between planting more of something and pulling it.
class NativityChip extends StatelessWidget {
  const NativityChip(this.nativity, {super.key});

  final String? nativity;

  @override
  Widget build(BuildContext context) {
    final n = nativity;
    if (n == null || n.isEmpty || n == 'unknown')
      return const SizedBox.shrink();
    final color = switch (n) {
      'native' => Press.sage,
      'invasive' => Press.oxblood,
      _ => Press.ochre, // introduced, cultivated
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        n.toUpperCase(),
        style: TextStyle(
          fontFamily: Type.mono,
          fontSize: 8.5,
          letterSpacing: 1.2,
          color: Press.paper,
        ),
      ),
    );
  }
}
