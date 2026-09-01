import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Where backups go. Pluggable per spec §11.5 — local folder ships first;
/// Google Drive and S3 implement the same interface later.
abstract class BackupTarget {
  Future<bool> exists(String path);
  Future<Uint8List> read(String path);
  Future<void> write(String path, Uint8List bytes);
  Future<List<String>> list(String prefix);

  /// Remove one object. Used only for DB-generation pruning (spec §11.7);
  /// blobs are never deleted by the backup process.
  Future<void> delete(String path);
  String get description;
}

/// Local directory target — also the base for "back up to a synced folder"
/// (Syncthing, Drive desktop client, USB copy).
class DirectoryTarget implements BackupTarget {
  DirectoryTarget(this.root);

  final Directory root;

  @override
  String get description => root.path;

  File _file(String path) => File(p.join(root.path, path));

  @override
  Future<bool> exists(String path) async => _file(path).existsSync();

  @override
  Future<Uint8List> read(String path) async => _file(path).readAsBytesSync();

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final f = _file(path);
    f.parent.createSync(recursive: true);
    // Write-then-rename so an interrupted write never leaves a corrupt blob.
    final tmp = File('${f.path}.tmp');
    tmp.writeAsBytesSync(bytes);
    tmp.renameSync(f.path);
  }

  @override
  Future<List<String>> list(String prefix) async {
    final dir = Directory(p.join(root.path, prefix));
    if (!dir.existsSync()) return const [];
    return [
      for (final e in dir.listSync(recursive: true))
        if (e is File && !e.path.endsWith('.tmp'))
          p.relative(e.path, from: root.path),
    ];
  }

  @override
  Future<void> delete(String path) async {
    final f = _file(path);
    if (f.existsSync()) f.deleteSync();
  }
}
