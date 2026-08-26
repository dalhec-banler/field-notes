import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Tiny JSON prefs (design README §6: layout, density, basemap, active
/// property are persisted user preferences).
class AppPrefs {
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
  }

  String? get activePropertyId => get<String>('active_property');
  set activePropertyId(String? id) => set('active_property', id);

  /// D-016: bulk downloads/uploads on cellular. Off by default.
  bool get allowCellular => get<bool>('allow_cellular') ?? false;
  set allowCellular(bool v) => set('allow_cellular', v);

  /// Daily automatic backup (spec §11.7). On by default once a backup has
  /// been set up; harmless before then.
  bool get autoBackup => get<bool>('auto_backup') ?? true;
  set autoBackup(bool v) => set('auto_backup', v);

  /// glove | dense — drives the ledger row scale factor.
  String get density => get<String>('density') ?? 'glove';
  set density(String v) => set('density', v);
}
