part of '../export_workspace.dart';

// Aerial is the sharp one (Esri, z19); the USGS quad blend caps at z16
// and costs that sharpness — say so on the chip (Austin, 2026-09-04:
// "doesn't look like we are using the high quality map"). The topo LOOK
// on sharp imagery is Aerial + the contour/hydro overlays.
const _bases = [
  ('aerial', 'Aerial — sharpest'),
  ('topo', 'USGS topo map'),
  ('blend', 'USGS quad — soft'),
];

const _docs = [('map', 'Map plate'), ('removal', 'Removal plan')];

/// The bench's state: layers, text fields, the subject and the plate,
/// the base and page choices, and the tile fetcher.
mixin _ExportCore on State<ExportWorkspace> {
  PlateLayers _layers = const PlateLayers();
  final _title = TextEditingController();
  final _preparedFor = TextEditingController();
  final _notes = TextEditingController();
  PlateSubject? _subject;
  PlateResult? _plate;
  bool _rendering = false;
  bool _saving = false;
  bool _detailsOpen = false;

  /// Species chosen for a species-coloured plate (empty = classic type
  /// colours, every record).
  final Set<String> _speciesSel = {};

  /// The plate's base: the live aerial source, USGS topo, or the blend —
  /// "aerial and topographic imagery as background", the property-map
  /// standard (2026-09-04).
  String _base = 'aerial';

  PlatePage _page = PlatePage.letter;

  /// Which sheet this is: the map plate, or the removal plan (D-027) —
  /// only flagged records, numbered, with the list beside them.
  String _doc = 'map';

  bool get _removalPlan => _doc == 'removal';

  (String template, int maxZoom, String label) get _baseSource =>
      switch (_base) {
        'topo' => (usgsTopoTemplate, 16, 'USGS Topo'),
        'blend' => (usgsImageryTopoTemplate, 16, 'USGS Imagery + Topo'),
        _ => (
          activeImagery.template,
          activeImagery.maxZoom,
          activeImagery.attribution,
        ),
      };
  String? _note; // warnings and save confirmations only
  int _seq = 0;
  Timer? _debounce;
  StreamSubscription<void>? _watch;

  /// Session tile caches, one per base — a topo tile must never answer
  /// for an aerial one.
  final _tileCaches = <String, TileCache>{};
  String _fetchKey = '';
  late TileFetcher _fetch = _buildFetcher();
  TileFetcher _buildFetcher() {
    final (template, _, _) = _baseSource;
    final primary = httpTileFetcher(template: template);
    final chained = _base == 'aerial' && activeImagery.id != 'usgs'
        ? tileFetcherWithFallback(primary, httpTileFetcher())
        : primary;
    _fetchKey = '$_base:${activeImagery.id}';
    return (_tileCaches[_fetchKey] ??= TileCache()).wrap(chained);
  }

  final _pageKey = GlobalKey();
}
