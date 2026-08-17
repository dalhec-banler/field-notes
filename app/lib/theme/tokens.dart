import 'package:flutter/material.dart';

/// Field Station design tokens — design handoff README §2. Exact values;
/// do not restate these anywhere else.
abstract final class Press {
  static const ink = Color(0xFF1B1813);
  static const inkSoft = Color(0xFF2C2620);
  static const paper = Color(0xFFECE3CE);
  static const paperRaised = Color(0xFFF4ECD8);
  static const paperEdge = Color(0xFFE2D7BE);
  static const oxblood = Color(0xFF7A2E1E);
  static const sage = Color(0xFF5F6B58);
  static const sageLight = Color(0xFF8E9B85);
  static const ochre = Color(0xFF8E6A28);
  static const ochreLight = Color(0xFFB58A3C);
  static const river = Color(0xFF3F5957);
  static const riverBlue = Color(0xFF5E6E8C);
  static const teal = Color(0xFF5C7A78);
  static const gold = Color(0xFFC99A45);
  static const cameraDark = Color(0xFF1E2C25);

  /// Row dividers inside cards: ink @ 9 %.
  static const divider = Color(0x181B1813);

  /// Photo placeholder fill.
  static const photoPlaceholder = Color(0xFFD6C9AC);
}

abstract final class Type {
  static const slab = 'ZillaSlab';
  static const serif = 'Newsreader';
  static const mono = 'JetBrainsMono';
}

abstract final class Metrics {
  /// Mobile screen gutter.
  static const gutter = 13.0;

  /// Card borders: 1.5 px ink. Structural dividers: 2 px.
  static const borderCard = 1.5;
  static const borderStructural = 2.0;

  static const touchMin = 56.0;
  static const fabSize = 66.0;
  static const shutterSize = 86.0;

  /// Hard offset shadows — never blur-fades.
  static const shadowCard = [
    BoxShadow(color: Color(0x471B1813), offset: Offset(4, 4)),
  ];
  static const shadowSheet = [
    BoxShadow(color: Color(0x4D1B1813), offset: Offset(6, 6)),
  ];
}

/// Survival bands (README §3.4): ≥80 sage · 60–79 ochre · <60 oxblood.
Color survivalBandColor(double rate) => rate >= 0.8
    ? Press.sage
    : rate >= 0.6
        ? Press.ochre
        : Press.oxblood;

/// Feature condition colours: good sage · fair ochre · poor/critical oxblood.
Color conditionColor(String? condition) => switch (condition) {
      'good' => Press.sage,
      'fair' => Press.ochre,
      'poor' || 'critical' => Press.oxblood,
      _ => Press.inkSoft,
    };

/// Plant status colours: alive sage · browsed ochre · dead oxblood ·
/// missing ink-soft.
Color plantStatusColor(String status) => switch (status) {
      'alive' || 'dormant' => Press.sage,
      'browsed' || 'declining' => Press.ochre,
      'dead' || 'removed' => Press.oxblood,
      _ => Press.inkSoft,
    };

/// Record-type diamond colours for pins and list rows.
Color recordTypeColor(String type) => switch (type) {
      'plant' || 'phenology' => Press.sage,
      'water' => Press.river,
      'problem' => Press.oxblood,
      'wildlife' || 'sign' => Press.ochre,
      'soil' => Press.ochreLight,
      _ => Press.inkSoft,
    };
