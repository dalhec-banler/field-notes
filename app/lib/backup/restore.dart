import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../db/database.dart';
import 'backup_crypto.dart';
import 'backup_engine.dart';
import 'keyring.dart';
import 'target.dart';

/// Restore pipeline (spec §11.9).
///
/// Staging: unpack + decrypt into `<docs>/restore_staged/` while the app is
/// running normally. Applying: on next launch, before the database opens, the
/// staged DB replaces the live one; after it opens, media paths are remapped
/// onto the restored blobs. DB-first, media-after — the app is usable the
/// moment it restarts.
class RestorePipeline {
  RestorePipeline(this.docsDir);

  final Directory docsDir;

  Directory get _staging => Directory(p.join(docsDir.path, 'restore_staged'));

  /// Unzips a shared backup archive and stages a restore from it.
  /// [secret] is tried as passphrase first, then as recovery phrase.
  /// Returns a summary. Throws with a clean message on wrong secret.
  Future<String> stageFromZip(File zip, {String? secret}) async {
    final tmp = Directory.systemTemp.createTempSync('fnrestore');
    try {
      await extractArchiveToDisk(
          ZipDecoder().decodeStream(InputFileStream(zip.path)), tmp.path);
      // The zip may contain the fieldnotes/ folder itself or its contents.
      var root = tmp;
      if (Directory(p.join(tmp.path, 'fieldnotes')).existsSync()) {
        // target layout expects <root>/fieldnotes/...
      } else if (File(p.join(tmp.path, 'manifest.json')).existsSync()) {
        // Contents were zipped without the folder: wrap them.
        final wrapped = Directory(p.join(tmp.path, 'fieldnotes'))
          ..createSync();
        for (final e in tmp.listSync()) {
          if (p.basename(e.path) == 'fieldnotes') continue;
          e.renameSync(p.join(wrapped.path, p.basename(e.path)));
        }
        root = tmp;
      }
      return await _stageFromTarget(DirectoryTarget(root), secret: secret);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }

  /// Stages a restore from an existing on-device backup store.
  Future<String> stageFromLocalStore({String? secret}) async {
    final store = Directory(p.join(docsDir.path, 'backups'));
    return _stageFromTarget(DirectoryTarget(store), secret: secret);
  }

  Future<String> _stageFromTarget(BackupTarget target,
      {String? secret}) async {
    final envelopeRaw = await target.read('${BackupEngine.root}/manifest.json');
    final envelope =
        jsonDecode(utf8.decode(envelopeRaw)) as Map<String, dynamic>;
    final scheme = envelope['scheme'] as String?;

    BackupCipher cipher;
    if (scheme == 'plain') {
      cipher = const PlainCipher();
    } else if (scheme == 'keyring-v1') {
      if (secret == null || secret.isEmpty) {
        throw StateError(
            'This backup is encrypted — enter the passphrase or recovery phrase.');
      }
      try {
        cipher =
            (await BackupKeyring.unlockWithPassphrase(envelope, secret)).cipher;
      } catch (_) {
        try {
          cipher = (await BackupKeyring.unlockWithRecoveryPhrase(
                  envelope, secret))
              .cipher;
        } catch (_) {
          throw StateError('That passphrase or recovery phrase is wrong.');
        }
      }
    } else {
      throw StateError('Unknown backup scheme: $scheme');
    }

    // A dummy engine bound to the source target does the decrypt work.
    final engine = BackupEngine(
        FieldNotesDb.forTesting(), target, cipher); // db unused by restore
    if (_staging.existsSync()) _staging.deleteSync(recursive: true);
    _staging.createSync(recursive: true);
    final result = await engine.restore(
      dbOut: File(p.join(_staging.path, 'db.sqlite')),
      mediaRestoreDir: Directory(p.join(_staging.path, 'media')),
    );
    File(p.join(_staging.path, 'READY')).writeAsStringSync(nowUtcIso());
    return '$result. Restart the app to finish.';
  }

  bool get hasStagedRestore =>
      File(p.join(_staging.path, 'READY')).existsSync();

  /// Pre-DB-open: swap the staged database into place. Returns true if a
  /// restore was applied.
  bool applyStagedDb(String liveDbPath) {
    if (!hasStagedRestore) return false;
    final staged = File(p.join(_staging.path, 'db.sqlite'));
    if (!staged.existsSync()) return false;
    final live = File(liveDbPath);
    if (live.existsSync()) {
      live.renameSync('$liveDbPath.pre-restore');
    }
    staged.copySync(liveDbPath);
    return true;
  }

  /// Post-DB-open: point media rows at the restored blobs.
  Future<int> remapRestoredMedia(FieldNotesDb db) async {
    final blobDir = Directory(p.join(_staging.path, 'media'));
    if (!blobDir.existsSync()) return 0;
    final destDir = Directory(p.join(docsDir.path, 'media', 'restored'))
      ..createSync(recursive: true);

    final rows = await (db.select(db.media)
          ..where((m) => m.sha256.isNotNull()))
        .get();
    var remapped = 0;
    for (final m in rows) {
      if (m.localPath != null && File(m.localPath!).existsSync()) continue;
      final blob = File(p.join(blobDir.path, '${m.sha256}.bin'));
      if (!blob.existsSync()) continue;
      final dest = p.join(destDir.path, '${m.id}.jpg');
      blob.copySync(dest);
      await (db.update(db.media)..where((x) => x.id.equals(m.id))).write(
        MediaCompanion(
          localPath: Value(dest),
          thumbPath: Value(dest),
          updatedAt: Value(nowUtcIso()),
        ),
      );
      remapped++;
    }
    // Staging served its purpose.
    _staging.deleteSync(recursive: true);
    return remapped;
  }
}
