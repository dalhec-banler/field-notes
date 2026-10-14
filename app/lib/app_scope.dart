import 'package:flutter/widgets.dart';

import 'db/database.dart';
import 'map/layers/layer_loader.dart';
import 'repo/repos.dart';
import 'services/app_prefs.dart';
import 'services/location_hub.dart';
import 'services/map_jump.dart';
import 'services/record_filter.dart';
import 'services/track_recorder.dart';
import 'sync/oplog.dart';
import 'theme/skin.dart' as theme;

/// The one place the app's process-wide things live (D-038 item 6): the
/// database and its repos, the op log, the GPS hub and track recorder,
/// the record filter, the pending map jump, the prefs.
///
/// `main()` builds one around the app and installs it; a test builds one
/// around the widget under test with an in-memory database. New code
/// reads `AppScope.of(context)`. The old module-level globals (`opLog`,
/// `locationHub`, `trackRecorder`, `recordFilter`, `mapJump`) still
/// resolve, as thin delegates to the installed scope, so nothing that
/// has not been converted yet breaks; they are legacy.
///
/// Lookups use [BuildContext.getInheritedWidgetOfExactType] — no rebuild
/// dependency is registered, because nothing here changes identity during
/// a run. The notifiers inside (filter, jump, hub, prefs) are listened to
/// directly, as before. Cache the scope in a `late final` field if a
/// `State` needs it in `dispose()`, where ancestor lookups are not allowed.
class AppScope extends InheritedWidget {
  AppScope({
    super.key,
    required this.db,
    required this.opLog,
    required this.locationHub,
    required this.trackRecorder,
    required this.recordFilter,
    required this.mapJump,
    required this.prefs,
    required super.child,
  }) : observations = ObservationsRepo(db),
       media = MediaRepo(db),
       zones = ZonesRepo(db),
       properties = PropertiesRepo(db),
       taxa = TaxaRepo(db),
       photoPoints = PhotoPointsRepo(db),
       mapLayers = MapLayerLoader(db);

  final FieldNotesDb db;

  /// This installation's change log; null only if capture failed to start.
  final OpLog? opLog;

  /// Single owner of the platform GPS stream.
  final LocationHub locationHub;

  /// Recording must survive navigation and screen sleep (spec §4.13).
  final TrackRecorder trackRecorder;

  /// The one filter the ledger writes and the map reads.
  final RecordFilter recordFilter;

  /// The one pending request to show a spot on a place's map (D-029).
  final ValueNotifier<MapJump?> mapJump;

  final AppPrefs prefs;

  final ObservationsRepo observations;
  final MediaRepo media;
  final ZonesRepo zones;
  final PropertiesRepo properties;
  final TaxaRepo taxa;
  final PhotoPointsRepo photoPoints;

  /// The one answer to "what does this place draw?" (D-038 item 11): the
  /// phone map reads it; the desk map and the plate build their own over
  /// the database they were handed.
  final MapLayerLoader mapLayers;

  /// The active skin. It stays a process-wide value decided before the
  /// first frame and swapped only through the root rebuild (D-023); the
  /// scope reads it rather than owning it, so it is current here too.
  theme.Skin get skin => theme.skin;

  static AppScope? _current;

  /// The scope `main()` (or a test) installed, if any.
  static AppScope? get maybeCurrent => _current;

  /// The installed scope; throws if there is none yet.
  static AppScope get current =>
      _current ??
      (throw StateError(
        'AppScope has not been installed. main() installs one before '
        'runApp; a test calls AppScope.install(...) or wraps the widget '
        'under test in an AppScope.',
      ));

  /// Make [scope] what the legacy globals resolve to. `main()` does this
  /// once; a test fixture may do it per test. Pass null to clear.
  static void install(AppScope? scope) => _current = scope;

  static AppScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>();

  /// The nearest scope above [context], else the installed one.
  static AppScope of(BuildContext context) =>
      maybeOf(context) ??
      _current ??
      (throw FlutterError(
        'AppScope.of() called with no AppScope in the tree and none '
        'installed. Wrap the app (or the widget under test) in AppScope.',
      ));

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      db != oldWidget.db ||
      opLog != oldWidget.opLog ||
      locationHub != oldWidget.locationHub ||
      trackRecorder != oldWidget.trackRecorder ||
      recordFilter != oldWidget.recordFilter ||
      mapJump != oldWidget.mapJump ||
      prefs != oldWidget.prefs;
}
