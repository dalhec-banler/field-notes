part of '../map_plate.dart';

/// Fetching: overlay images and the tile grid, with the plate's own
/// concurrency and retry rules.
extension _PlateFetch on MapPlate {
  /// One overlay image; the government endpoints hiccup (a 502 answered
  /// this exact request during development), so try three times and let
  /// a miss mean a missing layer, never a failed plate.
  Future<ui.Image?> _fetchOverlayImage(String url) async {
    final client = http.Client();
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final res = await client
              .get(Uri.parse(url), headers: {'User-Agent': 'FieldNotes/1.1'})
              .timeout(const Duration(seconds: 25));
          final b = res.bodyBytes;
          final isImage =
              b.length > 8 && (b[0] == 0x89 || (b[0] == 0xFF && b[1] == 0xD8));
          if (res.statusCode == 200 && isImage) {
            final codec = await ui.instantiateImageCodec(b);
            final img = (await codec.getNextFrame()).image;
            codec.dispose();
            return img;
          }
        } catch (e, st) {
          Diag.report(e, st, where: 'MapPlate._fetchOverlayImage');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      return null;
    } finally {
      client.close();
    }
  }

  Future<Map<(int, int), (ui.Image, ui.Rect)?>> _fetchAll(
    PlateFrame frame, {
    int? srcMaxZoom,
  }) async {
    final srcMax = srcMaxZoom ?? frame.zoom;
    final depth = (frame.zoom - srcMax).clamp(0, 8);
    final out = <(int, int), (ui.Image, ui.Rect)?>{};
    final queue = frame.tiles.toList();
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final (tx, ty) = queue.removeLast();
        // Past the source's cache: fetch the parent and note which
        // quadrant this tile is (the tile cache dedups the network).
        final bytes = depth == 0
            ? await fetchTile(frame.zoom, tx, ty)
            : await fetchTile(srcMax, tx >> depth, ty >> depth);
        (ui.Image, ui.Rect)? entry;
        if (bytes != null) {
          try {
            final codec = await ui.instantiateImageCodec(bytes);
            final img = (await codec.getNextFrame()).image;
            codec.dispose();
            if (depth == 0) {
              entry = (
                img,
                ui.Rect.fromLTWH(
                  0,
                  0,
                  img.width.toDouble(),
                  img.height.toDouble(),
                ),
              );
            } else {
              final sub = 1 << depth;
              final q = img.width / sub;
              entry = (
                img,
                ui.Rect.fromLTWH(
                  (tx & (sub - 1)) * q,
                  (ty & (sub - 1)) * q,
                  q,
                  q,
                ),
              );
            }
          } catch (e, st) {
            Diag.report(e, st, where: 'MapPlate._fetchAll');
            entry = null;
          }
        }
        out[(tx, ty)] = entry;
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    return out;
  }
}
