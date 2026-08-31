import 'package:flutter/material.dart';

/// A skin: every value the design system is allowed to vary (D-023).
///
/// The app has two. **Press** is the Field Station identity — paper and ink,
/// slab and mono, hard offset shadows, radius 0, uppercase letterspaced
/// labels, diamonds. **Quiet** is the contemporary default: system type,
/// soft radii, real elevation, sentence case, ornament off.
///
/// What a skin may NOT vary is field ergonomics: touch targets, the FAB and
/// shutter sizes, and outdoor-mode scaling live in [Metrics] and are shared.
/// A skin is a look, not a downgrade for gloved hands in the sun.
///
/// `lib/theme/tokens.dart` keeps the familiar `Press.*` / `Type.*` names and
/// delegates here, so call sites read the same as they always have; they
/// just can't be `const` any more. The active skin is a process-wide value
/// ([skin]) chosen from prefs before `runApp` and only ever changed through
/// the root rebuild in main.dart — never mid-frame.
class Skin {
  const Skin({
    required this.name,
    required this.ink,
    required this.inkSoft,
    required this.paper,
    required this.paperRaised,
    required this.paperEdge,
    required this.oxblood,
    required this.sage,
    required this.sageLight,
    required this.ochre,
    required this.ochreLight,
    required this.river,
    required this.riverBlue,
    required this.teal,
    required this.gold,
    required this.cameraDark,
    required this.divider,
    required this.photoPlaceholder,
    required this.slab,
    required this.serif,
    required this.mono,
    required this.radiusCard,
    required this.radiusControl,
    required this.shadowCard,
    required this.shadowSheet,
    required this.borderCard,
    required this.borderInk,
    required this.ornament,
    required this.upperLabels,
  });

  final String name;

  // Colours. Named for their press roles; the quiet skin maps the same
  // slots onto its own palette (ink = text, paper = surface, oxblood =
  // accent/destructive, sage/ochre = the survival bands, and so on).
  final Color ink;
  final Color inkSoft;
  final Color paper;
  final Color paperRaised;
  final Color paperEdge;
  final Color oxblood;
  final Color sage;
  final Color sageLight;
  final Color ochre;
  final Color ochreLight;
  final Color river;
  final Color riverBlue;
  final Color teal;
  final Color gold;
  final Color cameraDark;
  final Color divider;
  final Color photoPlaceholder;

  // Type. Null means the platform's own face.
  final String? slab; // display / headings
  final String? serif; // body
  final String? mono; // labels, data

  // Shape and depth.
  final double radiusCard;
  final double radiusControl;
  final List<BoxShadow> shadowCard;
  final List<BoxShadow> shadowSheet;
  final double borderCard;

  /// The colour card borders draw in. Press draws structure in ink; quiet
  /// draws a hairline in the surface's own edge tone.
  final Color borderInk;

  /// Diamonds, folio rules, the blinking status square — the press
  /// furniture. Off in quiet.
  final bool ornament;

  /// UPPERCASE LETTERSPACED labels vs sentence case.
  final bool upperLabels;

  /// Label text in this skin's casing.
  String label(String text) => upperLabels ? text.toUpperCase() : text;
}

/// The Field Station press identity — design handoff README §2, values
/// unchanged from the original constants.
const pressSkin = Skin(
  name: 'press',
  ink: Color(0xFF1B1813),
  inkSoft: Color(0xFF2C2620),
  paper: Color(0xFFECE3CE),
  paperRaised: Color(0xFFF4ECD8),
  paperEdge: Color(0xFFE2D7BE),
  oxblood: Color(0xFF7A2E1E),
  sage: Color(0xFF5F6B58),
  sageLight: Color(0xFF8E9B85),
  ochre: Color(0xFF8E6A28),
  ochreLight: Color(0xFFB58A3C),
  river: Color(0xFF3F5957),
  riverBlue: Color(0xFF5E6E8C),
  teal: Color(0xFF5C7A78),
  gold: Color(0xFFC99A45),
  cameraDark: Color(0xFF1E2C25),
  divider: Color(0x181B1813),
  photoPlaceholder: Color(0xFFD6C9AC),
  slab: 'ZillaSlab',
  serif: 'Newsreader',
  mono: 'JetBrainsMono',
  radiusCard: 0,
  radiusControl: 0,
  shadowCard: [BoxShadow(color: Color(0x471B1813), offset: Offset(4, 4))],
  shadowSheet: [BoxShadow(color: Color(0x4D1B1813), offset: Offset(6, 6))],
  borderCard: 1.5,
  borderInk: Color(0xFF1B1813),
  ornament: true,
  upperLabels: true,
);

/// The contemporary default (D-023): restrained, native-feeling, whitespace
/// doing the work the rules and borders do in press. Same semantic slots,
/// so survival still reads green/amber/red and destructive still reads red.
const quietSkin = Skin(
  name: 'quiet',
  ink: Color(0xFF1A1C1E),
  inkSoft: Color(0xFF44474A),
  paper: Color(0xFFFAFAF8),
  paperRaised: Color(0xFFFFFFFF),
  paperEdge: Color(0xFFE8E8E4),
  oxblood: Color(0xFFB3402E),
  sage: Color(0xFF3E7D4F),
  sageLight: Color(0xFF7FAE8C),
  ochre: Color(0xFFA97A1F),
  ochreLight: Color(0xFFC9A45C),
  river: Color(0xFF2F6D68),
  riverBlue: Color(0xFF4A6DA7),
  teal: Color(0xFF3D7A77),
  gold: Color(0xFFB98F3E),
  cameraDark: Color(0xFF14201A),
  divider: Color(0x141A1C1E),
  photoPlaceholder: Color(0xFFEDEDEA),
  slab: null,
  serif: null,
  mono: null,
  radiusCard: 12,
  radiusControl: 10,
  shadowCard: [
    BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 2)),
  ],
  shadowSheet: [
    BoxShadow(color: Color(0x1F000000), blurRadius: 24, offset: Offset(0, 6)),
  ],
  borderCard: 1,
  borderInk: Color(0xFFE8E8E4),
  ornament: false,
  upperLabels: false,
);

/// The active skin. Set from prefs in main() before runApp, and changed only
/// alongside the root-level rebuild — widgets read it freely during build
/// and never listen to it directly.
Skin skin = quietSkin;
