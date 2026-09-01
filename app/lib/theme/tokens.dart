import 'package:flutter/material.dart';

import 'skin.dart';

export 'skin.dart' show Skin, pressSkin, quietSkin, skin;

/// Design tokens, resolved through the active [skin] (D-023).
///
/// The names are the original Field Station ones — `Press.ink`,
/// `Type.serif` — because 1,400+ call sites already speak them and they
/// still read correctly under the quiet skin ("ink" is the text colour,
/// "paper" the surface, whatever the skin paints them). What changed is
/// that these are getters now, not consts: a call site may no longer write
/// `const TextStyle(color: Press.ink)`. The analyzer enforces that; when it
/// complains about a const here, the const is wrong, not the token.
abstract final class Press {
  static Color get ink => skin.ink;
  static Color get inkSoft => skin.inkSoft;
  static Color get paper => skin.paper;
  static Color get paperRaised => skin.paperRaised;
  static Color get paperEdge => skin.paperEdge;
  static Color get oxblood => skin.oxblood;
  static Color get sage => skin.sage;
  static Color get sageLight => skin.sageLight;
  static Color get ochre => skin.ochre;
  static Color get ochreLight => skin.ochreLight;
  static Color get river => skin.river;
  static Color get riverBlue => skin.riverBlue;
  static Color get teal => skin.teal;
  static Color get gold => skin.gold;
  static Color get cameraDark => skin.cameraDark;

  /// Card border colour: ink under press, a hairline edge tone under quiet.
  /// Pair it with [Metrics.borderCard] — never with a literal ink colour.
  static Color get borderInk => skin.borderInk;

  /// Row dividers inside cards.
  static Color get divider => skin.divider;

  /// Photo placeholder fill.
  static Color get photoPlaceholder => skin.photoPlaceholder;
}

abstract final class Type {
  static String? get slab => skin.slab;
  static String? get serif => skin.serif;
  static String? get mono => skin.mono;
}

/// Field ergonomics — shared by every skin, deliberately (D-023): a skin is
/// a look, and gloved thumbs in the sun get the same targets either way.
abstract final class Metrics {
  /// Mobile screen gutter.
  static const gutter = 13.0;

  /// Card borders (press); structural dividers.
  static double get borderCard => skin.borderCard;
  static const borderStructural = 2.0;

  static const touchMin = 56.0;
  static const fabSize = 66.0;
  static const shutterSize = 86.0;

  static List<BoxShadow> get shadowCard => skin.shadowCard;
  static List<BoxShadow> get shadowSheet => skin.shadowSheet;
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

/// Plant status colours: alive/dormant sage · browsed/declining ochre ·
/// dead/removed oxblood.
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
  'infrastructure' || 'maintenance' => Press.ink,
  _ => Press.inkSoft,
};
