import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'press.dart';

/// Photographs on a record, shown whole.
///
/// The old plate was sized by a phone/desk flag: 238 px and `BoxFit.cover` on
/// the phone path, which cropped a portrait photo to a letterbox strip, and a
/// fraction of the window height on the desk. Neither knew the shape of the
/// picture it was showing. This sizes to the photo's own aspect inside the
/// space it has, never crops, and never blows a picture up past the pixels it
/// actually has.
class PhotoPlate extends StatefulWidget {
  const PhotoPlate({
    super.key,
    required this.photos,
    required this.index,
    required this.onIndex,
    this.onDelete,
    this.maxHeight = 720,
  });

  /// Absolute paths, in the order they should be walked.
  final List<String> photos;
  final int index;
  final ValueChanged<int> onIndex;

  /// Called with the index to remove. Null hides the control.
  final ValueChanged<int>? onDelete;
  final double maxHeight;

  @override
  State<PhotoPlate> createState() => _PhotoPlateState();
}

class _PhotoPlateState extends State<PhotoPlate> {
  late final PageController _page = PageController(initialPage: widget.index);
  final _sizes = <String, Size>{};

  @override
  void didUpdateWidget(PhotoPlate old) {
    super.didUpdateWidget(old);
    // Someone moved the index from outside — a thumbnail, a keystroke.
    if (widget.index != old.index &&
        _page.hasClients &&
        _page.page?.round() != widget.index) {
      _page.jumpToPage(widget.index);
    }
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  /// Ask the decoder how big the picture is, so the plate can take its shape.
  Future<Size> _sizeOf(String path) async {
    final cached = _sizes[path];
    if (cached != null) return cached;
    final completer = Completer<Size>();
    final stream = FileImage(File(path)).resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      final s = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      );
      _sizes[path] = s;
      if (!completer.isCompleted) completer.complete(s);
    }, onError: (_, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete(const Size(4, 3));
    });
    stream.addListener(listener);
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) return const SizedBox.shrink();
    final n = widget.photos.length;
    return LayoutBuilder(
      builder: (context, box) {
        return FutureBuilder<Size>(
          future: _sizeOf(widget.photos[widget.index]),
          builder: (context, snap) {
            final nat = snap.data;
            final w = box.maxWidth;
            // Fit the photo's shape into the width we have, capped — and
            // never taller than the picture's own pixels, so nothing is
            // enlarged into mush.
            var h = nat == null ? w * 0.75 : w * (nat.height / nat.width);
            h = h.clamp(200.0, widget.maxHeight);
            if (nat != null && nat.height < h) h = nat.height;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: h,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ColoredBox(
                          color: Press.paperEdge,
                          child: PageView.builder(
                            controller: _page,
                            itemCount: n,
                            onPageChanged: widget.onIndex,
                            itemBuilder: (context, i) => GestureDetector(
                              onTap: () => _openLightbox(i),
                              child: Image.file(
                                File(widget.photos[i]),
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => Center(
                                  child: MonoLabel('PHOTO MISSING'),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (n > 1) ...[
                        _edge(Alignment.centerLeft, Icons.chevron_left, -1, n),
                        _edge(Alignment.centerRight, Icons.chevron_right, 1, n),
                        Positioned(
                          right: 10,
                          bottom: 10,
                          child: _pill('${widget.index + 1} / $n'),
                        ),
                      ],
                    ],
                  ),
                ),
                if (n > 1) _strip(n),
              ],
            );
          },
        );
      },
    );
  }

  Widget _edge(Alignment a, IconData icon, int step, int n) => Align(
    alignment: a,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: Press.paperRaised.withValues(alpha: 0.86),
        shape: CircleBorder(
          side: BorderSide(color: Press.borderInk, width: 1),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            final next = (widget.index + step) % n;
            widget.onIndex(next);
            if (_page.hasClients) {
              _page.animateToPage(
                next,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
              );
            }
          },
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 26, color: Press.ink),
          ),
        ),
      ),
    ),
  );

  Widget _pill(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    color: Press.ink.withValues(alpha: 0.72),
    child: MonoLabel(text, size: 9.5, color: Press.paper),
  );

  Widget _strip(int n) => Container(
    height: 62,
    margin: const EdgeInsets.only(top: 6),
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      itemCount: n,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (context, i) {
        final on = i == widget.index;
        return GestureDetector(
          onTap: () {
            widget.onIndex(i);
            if (_page.hasClients) {
              _page.animateToPage(
                i,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
              );
            }
          },
          child: Container(
            width: 56,
            decoration: BoxDecoration(
              border: Border.all(
                color: on ? Press.oxblood : Press.divider,
                width: on ? 2 : 1,
              ),
            ),
            child: Image.file(
              File(widget.photos[i]),
              fit: BoxFit.cover,
              cacheWidth: 160,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        );
      },
    ),
  );

  Future<void> _openLightbox(int start) async {
    final landed = await showPhotoLightbox(
      context,
      photos: widget.photos,
      index: start,
      onDelete: widget.onDelete,
    );
    if (landed != null && mounted) widget.onIndex(landed);
  }
}

/// Full-screen viewer: swipe or arrow between photographs, pinch or scroll to
/// zoom, Esc to leave. Returns the photo it was left on.
///
/// Delete reports the index actually on screen. The old viewer kept its own
/// cursor but deleted whatever the screen behind it had selected, so removing
/// a photo after paging removed the wrong one.
Future<int?> showPhotoLightbox(
  BuildContext context, {
  required List<String> photos,
  required int index,
  ValueChanged<int>? onDelete,
}) async {
  if (photos.isEmpty) return null;
  var current = index.clamp(0, photos.length - 1);
  final page = PageController(initialPage: current);
  final focus = FocusNode();

  await showDialog<void>(
    context: context,
    barrierColor: const Color(0xE61B1813),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialog) {
        void go(int step) {
          final next = (current + step) % photos.length;
          setDialog(() => current = next);
          page.animateToPage(
            next,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }

        return KeyboardListener(
          focusNode: focus,
          autofocus: true,
          onKeyEvent: (e) {
            if (e is! KeyDownEvent) return;
            if (e.logicalKey == LogicalKeyboardKey.arrowLeft) go(-1);
            if (e.logicalKey == LogicalKeyboardKey.arrowRight) go(1);
            if (e.logicalKey == LogicalKeyboardKey.escape) {
              Navigator.of(ctx).pop();
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: PageView.builder(
                  controller: page,
                  itemCount: photos.length,
                  onPageChanged: (i) => setDialog(() => current = i),
                  itemBuilder: (context, i) => InteractiveViewer(
                    minScale: 1,
                    maxScale: 6,
                    child: Center(
                      child: Image.file(
                        File(photos[i]),
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) =>
                            MonoLabel('PHOTO MISSING', color: Press.paper),
                      ),
                    ),
                  ),
                ),
              ),
              if (photos.length > 1) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    iconSize: 40,
                    color: Press.paper,
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => go(-1),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    iconSize: 40,
                    color: Press.paper,
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => go(1),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 22),
                    child: MonoLabel(
                      '${current + 1} / ${photos.length}',
                      color: Press.paper,
                    ),
                  ),
                ),
              ],
              if (onDelete != null)
                Positioned(
                  top: 16,
                  left: 16,
                  child: IconButton(
                    tooltip: 'Remove this photo',
                    color: Press.paper,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      final target = current;
                      Navigator.of(ctx).pop();
                      onDelete(target);
                    },
                  ),
                ),
              Positioned(
                top: 16,
                right: 16,
                child: IconButton(
                  color: Press.paper,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
  page.dispose();
  focus.dispose();
  return current;
}
