import 'package:flutter/material.dart';

import '../db/database.dart';
import '../screens/photo_points/photo_points_screen.dart';
import '../screens/plantings/plantings_screen.dart';
import '../screens/propagation/propagation_screen.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Grow (design README §3.4): sub-tab bar — Plantings · Propagation ·
/// Photo pts · Features. Active sub-tab carries a 3 px oxblood bottom border.
class GrowTab extends StatefulWidget {
  const GrowTab({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<GrowTab> createState() => _GrowTabState();
}

class _GrowTabState extends State<GrowTab> {
  int _sub = 0;

  static const _subs = [
    ('The growing record', 'Plantings'),
    ('Bench to riverbank', 'Propagation'),
    ('Repeat photography', 'Photo pts'),
  ];

  @override
  Widget build(BuildContext context) {
    final bodies = [
      PlantingsScreen(db: widget.db, property: widget.property, embedded: true),
      PropagationScreen(
        db: widget.db,
        property: widget.property,
        embedded: true,
      ),
      PhotoPointsScreen(
        db: widget.db,
        property: widget.property,
        embedded: true,
      ),
    ];

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(kicker: _subs[_sub].$1, title: _subs[_sub].$2),
          SizedBox(
            height: 56,
            child: Row(
              children: [
                for (var i = 0; i < _subs.length; i++)
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _sub = i),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: i == _sub
                                  ? Press.oxblood
                                  : Colors.transparent,
                              width: 3,
                            ),
                          ),
                        ),
                        child: Opacity(
                          opacity: i == _sub ? 1 : 0.55,
                          child: MonoLabel(
                            _subs[i].$2,
                            size: 9.5,
                            spacing: 1.4,
                            color: Press.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(index: _sub, children: bodies),
          ),
        ],
      ),
    );
  }
}
