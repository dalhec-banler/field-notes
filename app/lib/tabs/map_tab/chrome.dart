part of '../map_tab.dart';

/// The cards over the map: filter banner, capture frame, GPS badge,
/// property card, track toggle and the rest of the chrome.
mixin _MapTabChrome on _MapTabCamera {
  List<Widget> _chromeChildren() => [
    // Capture-area frame: the visible region is what gets captured.
    // The one filter, made visible and killable: the map shows only
    // what the ledger shows (Austin, 2026-09-04).
    if (_scope.recordFilter.active)
      Positioned(
        left: Metrics.gutter,
        right: Metrics.gutter,
        bottom: 104,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            color: Press.ink,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: MonoLabel(
                    'ONLY ${_scope.recordFilter.describe()}',
                    size: 9,
                    spacing: 1.2,
                    color: Press.paperRaised,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 12),
                InkWell(
                  onTap: _scope.recordFilter.clear,
                  child: MonoLabel(
                    'CLEAR',
                    size: 9,
                    spacing: 1.2,
                    color: Press.ochreLight,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    if (_captureMode)
      Positioned.fill(
        child: IgnorePointer(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 120, 22, 150),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Press.oxblood, width: 2),
              ),
            ),
          ),
        ),
      ),
    if (_captureMode)
      Positioned(
        left: 22,
        right: 22,
        bottom: 90,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: _captureArea,
                child: const Text('CAPTURE THIS AREA'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 56,
              child: OutlinedButton(
                onPressed: () => setState(() => _captureMode = false),
                child: const Text('CANCEL'),
              ),
            ),
          ],
        ),
      ),
    ListenableBuilder(
      listenable: _downloader,
      builder: (context, _) => _downloader.downloading
          ? Positioned(
              left: 22,
              right: 22,
              bottom: 90,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Press.ink,
                  border: Border.all(color: Press.paperEdge, width: 1.5),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: _downloader.progress,
                      color: Press.oxblood,
                      backgroundColor: const Color(0x33ECE3CE),
                    ),
                    const SizedBox(height: 7),
                    MonoLabel(
                      _downloader.status ?? 'Capturing…',
                      size: 9.5,
                      color: Press.paper,
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox.shrink(),
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
                // Flexible: a long place name wraps inside the card
                // instead of pushing the controls off the screen.
                Flexible(
                  child: GestureDetector(
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
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
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
                              widget.property.landTenure.replaceAll('_', ' '),
                            ].join(' · '),
                            size: 9,
                            spacing: 1.4,
                            opacity: 0.8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _TrackToggle(propertyId: widget.property.id),
                    const SizedBox(height: 7),
                    GestureDetector(
                      onTap: _editShapes,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Press.paper,
                          border: Border.all(
                            color: Press.borderInk,
                            width: 1.5,
                          ),
                        ),
                        child: MonoLabel(
                          '✎ Zones',
                          size: 9.5,
                          spacing: 1.2,
                          color: Press.ink,
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    GestureDetector(
                      onTap: () => setState(() => _captureMode = !_captureMode),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: _captureMode ? Press.oxblood : Press.paper,
                          border: Border.all(
                            color: Press.borderInk,
                            width: 1.5,
                          ),
                        ),
                        child: MonoLabel(
                          '⌗ Capture area',
                          size: 9.5,
                          spacing: 1.4,
                          color: _captureMode ? Press.paper : Press.ink,
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    // Layers: record types, zones, tracks.
                    GestureDetector(
                      onTap: _showLayersSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: _layersTouched ? Press.ink : Press.paper,
                          border: Border.all(
                            color: Press.borderInk,
                            width: 1.5,
                          ),
                        ),
                        child: MonoLabel(
                          _layersTouched ? '◈ Layers · filtered' : '◈ Layers',
                          size: 9.5,
                          spacing: 1.4,
                          color: _layersTouched ? Press.paper : Press.ink,
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    // GPS: status readout AND the locate-me control.
                    // Tap → fly to the current fix.
                    ListenableBuilder(
                      listenable: _scope.locationHub,
                      builder: (context, _) {
                        // While a track runs the stream is distance-
                        // filtered, so standing still is silence, not
                        // a lost fix — trust the last one then.
                        final fix =
                            _scope.locationHub.fresh() ??
                            (_scope.locationHub.foreground
                                ? _scope.locationHub.last
                                : null);
                        final presence = fix == null
                            ? SitePresence.unknown
                            : presenceFor(
                                widget.property,
                                fix.latitude,
                                fix.longitude,
                              );
                        // Off the property, the useful move is to show
                        // the property — not to drag the map to town.
                        final offSite =
                            fix != null &&
                            !presence.onSite &&
                            presence.distanceM != null;
                        final label = fix == null
                            ? 'GPS · searching'
                            : offSite
                            ? '${presence.awayLabel} · show the place'
                            : 'GPS ±${fix.accuracy.toStringAsFixed(0)} m · find me';
                        return GestureDetector(
                          onTap: fix == null
                              ? null
                              : offSite
                              ? _flyToProperty
                              : () => _flyTo(fix),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Press.paper,
                              border: Border.all(
                                color: fix == null
                                    ? Press.sage
                                    : offSite
                                    ? Press.ochre
                                    : Press.ink,
                                width: 1.5,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Diamond(
                                  size: 9,
                                  color: fix == null
                                      ? Press.sage
                                      : offSite
                                      ? Press.ochre
                                      : Press.river,
                                  filled: fix != null,
                                  blink: fix == null,
                                ),
                                const SizedBox(width: 6),
                                MonoLabel(
                                  label,
                                  size: 9.5,
                                  spacing: 1.4,
                                  color: fix == null
                                      ? Press.sage
                                      : offSite
                                      ? Press.ochre
                                      : Press.ink,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  ];
}

class _TrackToggle extends StatelessWidget {
  const _TrackToggle({required this.propertyId});
  final String propertyId;

  @override
  Widget build(BuildContext context) {
    final trackRecorder = AppScope.of(context).trackRecorder;
    return ListenableBuilder(
      listenable: trackRecorder,
      builder: (context, _) {
        final on =
            trackRecorder.recording &&
            trackRecorder.activePropertyId == propertyId;
        return GestureDetector(
          onTap: () async {
            if (on) {
              await trackRecorder.stop();
            } else if (!trackRecorder.recording) {
              await trackRecorder.start(propertyId);
              // A recorder that can't hear the GPS must say so, not sit
              // at 0.0 km looking busy.
              final err = trackRecorder.lastError;
              if (err != null && context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(err)));
              }
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: on ? Press.oxblood : Press.paper,
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: MonoLabel(
              on
                  ? trackRecorder.lastError != null
                        ? '◼ Track · GPS lost'
                        : '◼ Track ${(trackRecorder.distanceSoFarM / 1000).toStringAsFixed(1)} km'
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
