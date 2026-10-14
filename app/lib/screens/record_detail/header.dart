part of '../record_detail_screen.dart';

/// The way back, the photographs and the title block.
mixin _RecordHeader on _RecordEdits {
  /// A record opened as its own route needs a way back. Pushed from the
  /// Ledger on the desk there is no system gesture to fall back on, and this
  /// chip used to live inside the photo header — where a layout change lost
  /// it. It floats over the whole view now, on paper so it reads against any
  /// photograph, and Esc does the same thing for a keyboard.
  Widget _withBack(Widget child) {
    if (widget.embedded) return child;
    void back() {
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    }

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              back();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              Positioned.fill(child: child),
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                left: 8,
                child: Material(
                  color: Press.paper,
                  shape: Border.all(color: Press.ink, width: 1.5),
                  child: InkWell(
                    onTap: back,
                    child: const SizedBox(
                      width: 52,
                      height: 52,
                      child: Icon(Icons.arrow_back, size: 24),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Photographs and title block — the first children of the page.
  List<Widget> _headerChildren(Observation obs, Color typeColor) => [
          // 1. Photographs. Sized to the picture's own shape inside the
          // space available — never cropped, never enlarged past its pixels.
          // A record with no photo gets a slim bar instead of a third of the
          // screen in blank paper.
          if (_photos.isEmpty)
            SizedBox(height: 64 + MediaQuery.of(context).padding.top)
          else
            Padding(
              padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
              child: PhotoPlate(
                photos: [for (final m in _photos) m.localPath!],
                index: _photoIndex.clamp(0, _photos.length - 1),
                onIndex: (i) => setState(() => _photoIndex = i),
                onDelete: (i) {
                  setState(() => _photoIndex = i);
                  _deleteCurrentPhoto();
                },
                maxHeight: widget.embedded ? 620 : 460,
              ),
            ),
          // 2. Title block.
          Padding(
            padding: EdgeInsets.fromLTRB(Metrics.gutter, 14, Metrics.gutter, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(width: 14, height: 2, color: Press.oxblood),
                    SizedBox(width: 7),
                    MonoLabel(
                      '${obs.observationType}'
                      '${_taxon != null && kConfidenceLabels.containsKey(obs.taxonConfidence) ? ' · ${kConfidenceLabels[obs.taxonConfidence]}' : ''}',
                      size: 9,
                      spacing: 1.8,
                      color: typeColor,
                    ),
                  ],
                ),
                if (obs.removalStatus != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: RemovalChip(
                        obs.removalStatus,
                        removedOn: obs.removedOn,
                      ),
                    ),
                  ),
                SizedBox(height: 8),
                if (_taxon != null) ...[
                  // Name → the species' whole history on this place.
                  GestureDetector(
                    onTap: _property == null
                        ? null
                        : () => showSpeciesDetailSheet(
                            context,
                            db: widget.db,
                            property: _property!,
                            taxon: _taxon!,
                          ),
                    child: TaxonName(_taxon!.scientificName, size: 34),
                  ),
                  SizedBox(height: 5),
                  Text(
                    [
                      if (_taxon!.commonName != null) _taxon!.commonName!,
                      if (_taxon!.family != null) _taxon!.family!,
                    ].join(' · ').toUpperCase(),
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Press.ink,
                    ),
                  ),
                  if (_taxon!.nativity != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: NativityChip(_taxon!.nativity),
                      ),
                    ),
                ] else
                  Text(
                    obs.observationType.toUpperCase(),
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w900,
                      fontSize: 30,
                      height: 0.9,
                      color: Press.ink,
                    ),
                  ),
                // Pending-visible review (SYNC-DESIGN): the tag rides the
                // record so a contributor's edit is never mistaken for a
                // settled fact — and never hidden either.
                if (_review != null && _review!.state == 'pending') ...[
                  SizedBox(height: 8),
                  StatusPill('pending review', color: Press.ochre),
                ],
              ],
            ),
          ),
  ];
}
