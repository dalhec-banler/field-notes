import 'package:flutter/material.dart';

import '../db/database.dart';
import '../main.dart' show trackRecorder;
import '../map/map_screen.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Map home (design README §3.1): full-bleed map with card chrome — property
/// card (tap = property switcher), track toggle, GPS badge.
class MapTab extends StatefulWidget {
  const MapTab({
    super.key,
    required this.db,
    required this.property,
    required this.onPropertyCardTap,
  });

  final FieldNotesDb db;
  final Property property;
  final VoidCallback onPropertyCardTap;

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  int _zoneCount = 0;

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  @override
  void didUpdateWidget(MapTab old) {
    super.didUpdateWidget(old);
    if (old.property.id != widget.property.id) _loadCounts();
  }

  Future<void> _loadCounts() async {
    final zones = await (widget.db.select(widget.db.zones)
          ..where((z) => z.propertyId.equals(widget.property.id))
          ..where((z) => z.deletedAt.isNull()))
        .get();
    if (mounted) setState(() => _zoneCount = zones.length);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          // KeyedSubtree so switching properties rebuilds the map + overlays.
          child: KeyedSubtree(
            key: ValueKey(widget.property.id),
            child: MapScreen(
                db: widget.db, property: widget.property, embedded: true),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Property card — hard offset shadow; the switcher.
                    GestureDetector(
                      onTap: widget.onPropertyCardTap,
                      child: InkCard(
                        color: Press.paper,
                        shadow: true,
                        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.property.name.toUpperCase(),
                              style: const TextStyle(
                                fontFamily: Type.slab,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                color: Press.ink,
                              ),
                            ),
                            const SizedBox(height: 3),
                            MonoLabel(
                              [
                                if (_zoneCount > 0) '$_zoneCount zones',
                                if (widget.property.acreage != null)
                                  '${widget.property.acreage!.toStringAsFixed(2)} ac',
                                widget.property.landTenure
                                    .replaceAll('_', ' '),
                              ].join(' · '),
                              size: 9,
                              spacing: 1.4,
                              opacity: 0.8,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _TrackToggle(propertyId: widget.property.id),
                        const SizedBox(height: 7),
                        // GPS badge with the blinking diamond.
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 6),
                          decoration: BoxDecoration(
                            color: Press.paper,
                            border:
                                Border.all(color: Press.sage, width: 1.5),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Diamond(
                                  size: 9, color: Press.sage, blink: true),
                              SizedBox(width: 6),
                              MonoLabel('GPS',
                                  size: 9, spacing: 1.4, color: Press.sage),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TrackToggle extends StatelessWidget {
  const _TrackToggle({required this.propertyId});
  final String propertyId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: trackRecorder,
      builder: (context, _) {
        final on = trackRecorder.recording &&
            trackRecorder.activePropertyId == propertyId;
        return GestureDetector(
          onTap: () async {
            if (on) {
              await trackRecorder.stop();
            } else if (!trackRecorder.recording) {
              await trackRecorder.start(propertyId);
            }
          },
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: on ? Press.oxblood : Press.paper,
              border: Border.all(color: Press.ink, width: 1.5),
            ),
            child: MonoLabel(
              on
                  ? '◼ Track ${(trackRecorder.distanceSoFarM / 1000).toStringAsFixed(1)} km'
                  : '▶ Log track',
              size: 9.5,
              spacing: 1.4,
              color: on ? Press.paper : Press.ink,
            ),
          ),
        );
      },
    );
  }
}
