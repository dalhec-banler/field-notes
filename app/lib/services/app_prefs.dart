import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Tiny JSON prefs (design README §6: layout, density, basemap, active
/// property are persisted user preferences).
class AppPrefs extends ChangeNotifier {
  AppPrefs._(this._file, this._data);

  final File _file;
  final Map<String, dynamic> _data;

  static Future<AppPrefs> load() async {
    final docs = await getApplicationDocumentsDirectory();
    final file = File(p.join(docs.path, 'prefs.json'));
    Map<String, dynamic> data = {};
    if (file.existsSync()) {
      try {
        data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {}
    }
    return AppPrefs._(file, data);
  }

  T? get<T>(String key) => _data[key] as T?;

  void set(String key, Object? value) {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    _file.writeAsStringSync(jsonEncode(_data));
    notifyListeners();
  }

  /// The computer this phone last paired with for LAN backup.
  String? get lanHost => get<String>('lan_host');
  set lanHost(String? v) => set('lan_host', v);
  String? get lanCode => get<String>('lan_code');
  set lanCode(String? v) => set('lan_code', v);
  /// The Google account backups go to, remembered only so the Backup screen
  /// can say which one without a silent sign-in on every visit.
  String? get driveEmail => get<String>('drive_email');
  set driveEmail(String? v) => set('drive_email', v);

  /// First run shows the walkthrough once; Settings can reopen it.
  bool get hasSeenOnboarding => get<bool>('seen_onboarding') ?? false;
  set hasSeenOnboarding(bool v) => set('seen_onboarding', v);

  /// Spec §7 "high-contrast outdoor mode": bigger type, glove density.
  /// The paper/ink palette is already ~12:1; what direct sun takes is size.
  bool get outdoorMode => get<bool>('outdoor_mode') ?? false;
  set outdoorMode(bool v) => set('outdoor_mode', v);

  String? get activePropertyId => get<String>('active_property');
  set activePropertyId(String? id) => set('active_property', id);

  /// D-016: bulk downloads/uploads on cellular. Off by default.
  bool get allowCellular => get<bool>('allow_cellular') ?? false;
  set allowCellular(bool v) => set('allow_cellular', v);

  /// Daily automatic backup (spec §11.7). On by default once a backup has
  /// been set up; harmless before then.
  bool get autoBackup => get<bool>('auto_backup') ?? true;
  set autoBackup(bool v) => set('auto_backup', v);

  /// Weather + soil lookup for each record (spec §4.11).
  ///
  /// Defaults to **off**, and is the only setting in the app whose default is
  /// chosen against the feature: it is the one path that sends a location to
  /// a third party without the user asking for it in the moment, and the
  /// app's first rule is that coordinates of private land don't leave the
  /// device unprompted. On, the coordinate is rounded to ~1 km first.
  bool get envContext => get<bool>('env_context') ?? false;
  set envContext(bool v) => set('env_context', v);

  /// Which skin the app wears (D-023): 'quiet' (default) or 'press'.
  String get skinName => get<String>('skin') ?? 'quiet';
  set skinName(String v) => set('skin', v);

  /// Whether the press skin has been discovered (seven taps on the version
  /// row). Once found, the Appearance row shows and stays shown.
  bool get pressUnlocked => get<bool>('press_unlocked') ?? false;
  set pressUnlocked(bool v) => set('press_unlocked', v);

  /// glove | dense — drives the ledger row scale factor.
  String get density => get<String>('density') ?? 'glove';
  set density(String v) => set('density', v);
}
