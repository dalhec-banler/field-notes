import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The system's mark: a 45°-rotated square. Never a circle, never an icon.
class Diamond extends StatelessWidget {
  Diamond({
    super.key,
    required this.size,
    required this.color,
    this.filled = true,
    this.blink = false,
  });

  final double size;
  final Color color;
  final bool filled;
  final bool blink;

  @override
  Widget build(BuildContext context) {
    final square = Transform.rotate(
      angle: math.pi / 4,
      child: Container(
        width: size / 1.414,
        height: size / 1.414,
        decoration: BoxDecoration(
          color: filled ? color : null,
          border: filled ? null : Border.all(color: color, width: 1.5),
        ),
      ),
    );
    final sized = SizedBox(width: size, height: size, child: Center(child: square));
    return blink ? _Blink(child: sized) : sized;
  }
}

class _Blink extends StatefulWidget {
  _Blink({required this.child});
  final Widget child;

  @override
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
      vsync: this, duration: Duration(milliseconds: 2000))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity:
            Tween(begin: 0.35, end: 1.0).animate(CurvedAnimation(
                parent: _controller, curve: Curves.easeInOut)),
        child: widget.child,
      );
}

/// Kicker: 14×2 px oxblood rule + Mono 9 uppercase label.
class Kicker extends StatelessWidget {
  Kicker(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 14, height: 2, color: Press.oxblood),
        SizedBox(width: 7),
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: TextStyle(
              fontFamily: Type.mono,
              fontSize: 9,
              letterSpacing: 2.0,
              color: Press.inkSoft,
            ),
          ),
        ),
      ],
    );
  }
}

/// Screen header: kicker + Zilla Slab 900 uppercase title (+ optional
/// right-aligned annotation), over a 2 px structural rule.
class ScreenHeader extends StatelessWidget {
  ScreenHeader({
    super.key,
    required this.kicker,
    required this.title,
    this.trailing,
  });

  final String kicker;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          Metrics.gutter, 10, Metrics.gutter, 10),
      decoration: BoxDecoration(
        border: Border(
            bottom:
                BorderSide(color: Press.borderInk, width: Metrics.borderStructural)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Kicker(kicker),
                SizedBox(height: 4),
                Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    fontFamily: Type.slab,
                    fontWeight: FontWeight.w900,
                    fontSize: 30,
                    height: 0.9,
                    letterSpacing: 0.6,
                    color: Press.ink,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Card with the canonical 1.5 px ink border on paper-raised.
class InkCard extends StatelessWidget {
  // Colour defaults resolve in build — a default parameter must be
  // constant, and tokens no longer are (D-023).
  InkCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.color,
    this.borderColor,
    this.shadow = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final Color? borderColor;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? Press.paperRaised,
        border:
            Border.all(color: borderColor ?? Press.borderInk, width: Metrics.borderCard),
        boxShadow: shadow ? Metrics.shadowCard : null,
      ),
      child: child,
    );
  }
}

/// Mono uppercase label — the instrumental voice.
class MonoLabel extends StatelessWidget {
  MonoLabel(
    this.text, {
    super.key,
    this.size = 9.5,
    this.spacing = 1.5,
    this.color,
    this.opacity = 1,
    this.weight = FontWeight.w400,
    this.maxLines,
  });

  final String text;
  final double size;
  final double spacing;
  final Color? color;
  final double opacity;
  final FontWeight weight;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      maxLines: maxLines,
      overflow: maxLines != null ? TextOverflow.ellipsis : null,
      style: TextStyle(
        fontFamily: Type.mono,
        fontWeight: weight,
        fontSize: size,
        letterSpacing: spacing,
        color: (color ?? Press.inkSoft).withValues(alpha: opacity),
      ),
    );
  }
}

/// Scientific name — Newsreader italic, always.
class TaxonName extends StatelessWidget {
  TaxonName(this.name, {super.key, this.size = 19, this.maxLines});
  final String name;
  final double size;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    return Text(
      name,
      maxLines: maxLines,
      overflow: maxLines != null ? TextOverflow.ellipsis : null,
      style: TextStyle(
        fontFamily: Type.serif,
        fontStyle: FontStyle.italic,
        fontSize: size,
        height: 0.98,
        color: Press.ink,
      ),
    );
  }
}

/// Big number — Zilla Slab 900 with an optional Mono unit.
class BigNumber extends StatelessWidget {
  BigNumber(this.value, {super.key, this.unit, this.size = 25, this.color});
  final String value;
  final String? unit;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: value,
          style: TextStyle(
            fontFamily: Type.slab,
            fontWeight: FontWeight.w900,
            fontSize: size,
            height: 1,
            color: color ?? Press.ink,
          ),
        ),
        if (unit != null)
          TextSpan(
            text: ' ${unit!.toUpperCase()}',
            style: TextStyle(
              fontFamily: Type.mono,
              fontSize: size * 0.4,
              letterSpacing: 1.2,
              color: (color ?? Press.ink).withValues(alpha: 0.7),
            ),
          ),
      ]),
    );
  }
}

/// Status pill: 999 px radius, 1 px border, Mono uppercase. `filled` is
/// reserved for critical states readable at arm's length.
class StatusPill extends StatelessWidget {
  const StatusPill(this.text,
      {super.key, required this.color, this.filled = false});
  final String text;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
      decoration: BoxDecoration(
        color: filled ? color : null,
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: Type.mono,
          fontSize: 8.5,
          letterSpacing: 1.3,
          color: filled ? Press.paper : color,
        ),
      ),
    );
  }
}

/// Rail note: 3 px coloured left border on a tinted fill — the voice for
/// explanations with a stake (oxblood), interpretation (ochre), mechanism
/// (sage).
class RailNote extends StatelessWidget {
  const RailNote({
    super.key,
    required this.color,
    this.label,
    required this.body,
  });

  final Color color;
  final String? label;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            MonoLabel(label!, size: 9, spacing: 1.8, color: color),
            const SizedBox(height: 5),
          ],
          Text(
            body,
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 15,
              height: 1.45,
              color: Press.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// A row of stat cells separated by 1 px ink gaps on a 1.5 px ink base.
class StatCells extends StatelessWidget {
  const StatCells({super.key, required this.cells});

  /// (label, value, unit?)
  final List<(String, String, String?)> cells;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration:
          BoxDecoration(border: Border.all(color: Press.borderInk, width: 1.5)),
      child: IntrinsicHeight(
        child: Row(
          children: [
            for (var i = 0; i < cells.length; i++) ...[
              if (i > 0) Container(width: 1, color: Press.ink),
              Expanded(
                child: Container(
                  color: Press.paperRaised,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MonoLabel(cells[i].$1, size: 8.5, spacing: 1.6),
                      const SizedBox(height: 4),
                      BigNumber(cells[i].$2, unit: cells[i].$3),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Key/value fact row: schema field names as keys, Mono values.
class FactRow extends StatelessWidget {
  const FactRow(this.fieldName, this.value,
      {super.key, this.valueWidget, this.last = false});
  final String fieldName;
  final String value;
  final Widget? valueWidget;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: Press.divider, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: MonoLabel(fieldName, size: 9, spacing: 1.4, opacity: 0.65),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: valueWidget ??
                Text(
                  value,
                  style: TextStyle(
                    fontFamily: Type.mono,
                    fontSize: 11.5,
                    height: 1.45,
                    color: Press.ink,
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

/// The capture FAB — 66 px oxblood circle with a 3 px paper-edge ring.
class CaptureFab extends StatelessWidget {
  const CaptureFab({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: Metrics.fabSize,
        height: Metrics.fabSize,
        decoration: BoxDecoration(
          color: Press.oxblood,
          shape: BoxShape.circle,
          border: Border.all(color: Press.paperEdge, width: 3),
          boxShadow: const [
            BoxShadow(color: Color(0x551B1813), offset: Offset(0, 3), blurRadius: 8),
          ],
        ),
        child: Icon(Icons.add_a_photo_outlined,
            color: Press.paper, size: 26),
      ),
    );
  }
}
