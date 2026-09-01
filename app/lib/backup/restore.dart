import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../id/id_keys.dart';

import 'package:sqlite3/sqlite3.dart' as sqlite;

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
///
/// Two markers keep the two phases honest:
///  * `READY`   — staging is complete and verified; apply the DB on next launch.
///                Consumed the moment the swap succeeds, so a crash or error
///                during media remap can never re-apply the snapshot over
///                records written since.
///  * `APPLIED` — DB swapped; media remap still owed. Remap is idempotent and
///                keeps retrying on later launches until every blob is placed.
class RestorePipeline {
  RestorePipeline(this.docsDir);

  final Directory docsDir;

  Directory get _staging => Directory(p.join(docsDir.path, 'restore_staged'));
  File get _ready => File(p.join(_staging.path, 'READY'));
  File get _applied => File(p.join(_staging.path, 'APPLIED'));

  /// Unzips a shared backup archive and stages a restore from it.
  /// [secret] is tried as passphrase first, then as recovery phrase.
  /// Returns a summary. Throws with a clean message on wrong secret.
  Future<String> stageFromZip(File zip, {String? secret}) async {
    final tmp = Directory.systemTemp.createTempSync('fnrestore');
    try {
      await extractArchiveToDisk(
        ZipDecoder().decodeStream(InputFileStream(zip.path)),
        tmp.path,
      );
      // The zip may contain the fieldnotes/ folder itself or its contents.
      var root = tmp;
      if (Directory(p.join(tmp.path, 'fieldnotes')).existsSync()) {
        // target layout expects <root>/fieldnotes/...
      } else if (File(p.join(tmp.path, 'manifest.json')).existsSync()) {
        // Contents were zipped without the folder: wrap them.
        final wrapped = Directory(p.join(tmp.path, 'fieldnotes'))..createSync();
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

  /// Stage a restore from any backup target — the Drive app folder, a LAN
  /// receiver, wherever. Same pipeline, same integrity refusal, same
  /// restart-to-apply contract as every other source (audit P3: a backup
  /// you can't restore from isn't one).
  Future<String> stageFromTarget(BackupTarget target, {String? secret}) =>
      _stageFromTarget(target, secret: secret);

  Future<String> _stageFromTarget(BackupTarget target, {String? secret}) async {
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
          'This backup is encrypted — enter the passphrase or recovery phrase.',
        );
      }
      try {
        cipher = (await BackupKeyring.unlockWithPassphrase(
          envelope,
          secret,
        )).cipher;
      } catch (_) {
        try {
          cipher = (await BackupKeyring.unlockWithRecoveryPhrase(
            envelope,
            secret,
          )).cipher;
        } catch (_) {
          throw StateError('That passphrase or recovery phrase is wrong.');
        }
      }
    } else {
      throw StateError('Unknown backup scheme: $scheme');
    }

    // A dummy engine bound to the source target does the decrypt work.
    final dummy = FieldNotesDb.forTesting(); // db unused by restore
    final engine = BackupEngine(dummy, target, cipher);
    if (_staging.existsSync()) _staging.deleteSync(recursive: true);
    _staging.createSync(recursive: true);
    final stagedDb = File(p.join(_staging.path, 'db.sqlite'));
    final String result;
    try {
      result = await engine.restore(
        dbOut: stagedDb,
        mediaRestoreDir: Directory(p.join(_staging.path, 'media')),
      );
      // Keys that rode inside the sealed body go straight to this device's
      // keystore — they don't wait for the DB swap and never touch disk.
      final secrets = engine.restoredSecrets;
      if (secrets != null && secrets.isNotEmpty) {
        await IdKeys().importAll(secrets);
      }
    } finally {
      await dummy.close();
    }

    // Never promise a database we haven't opened. A corrupt dump is refused
    // here, where the live data is still untouched.
    final verdict = _integrityCheck(stagedDb);
    if (verdict != 'ok') {
      _staging.deleteSync(recursive: true);
      throw StateError(
        'The backup\'s database failed its integrity check '
        '($verdict). Nothing was changed.',
      );
    }

    _ready.writeAsStringSync(nowUtcIso());
    // Remember where this copy came from, so a desk can tell when the
    // phone has put a newer one in the same place.
    try {
      _restoredFrom.writeAsStringSync(
        jsonEncode({
          'generation': envelope['generation'],
          'created_at': envelope['created_at'],
          'scheme': scheme,
          'source': target.description,
          'staged_at': nowUtcIso(),
        }),
      );
    } catch (_) {}
    return '$result. Restart the app to finish.';
  }

  File get _restoredFrom => File(p.join(docsDir.path, 'restored_from.json'));

  /// The manifest this device's copy was last restored from, or null.
  Map<String, dynamic>? get lastRestoredFrom {
    try {
      if (!_restoredFrom.existsSync()) return null;
      return jsonDecode(_restoredFrom.readAsStringSync())
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static String _integrityCheck(File dbFile) {
    try {
      final db = sqlite.sqlite3.open(
        dbFile.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        final rows = db.select('PRAGMA integrity_check');
        if (rows.isEmpty) return 'no result';
        return '${rows.first.values.first}';
      } finally {
        db.close();
      }
    } catch (e) {
      return '$e';
    }
  }

  bool get hasStagedRestore => _ready.existsSync();

  /// True after the DB swap until every restored blob has been placed.
  bool get hasPendingMediaRemap => _applied.existsSync();

  /// Pre-DB-open: swap the staged database into place. Returns true if a
  /// restore was applied. Consumes `READY` immediately on success.
  bool applyStagedDb(String liveDbPath) {
    if (!hasStagedRestore) return false;
    final staged = File(p.join(_staging.path, 'db.sqlite'));
    if (!staged.existsSync()) return false;

    // Move the live DB AND its sidecars aside together. A hot -journal or
    // -wal left behind would be "rolled back" into the restored file the
    // moment SQLite opens it.
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp('[:.]'),
      '-',
    );
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      final f = File('$liveDbPath$suffix');
      if (f.existsSync()) {
        f.renameSync('$liveDbPath.pre-restore-$stamp$suffix');
      }
    }
    staged.copySync(liveDbPath);

    // Swap done: from here on the snapshot must never be applied again.
    _ready.deleteSync();
    _applied.writeAsStringSync(nowUtcIso());
    return true;
  }

  /// Post-DB-open: point media rows at the restored blobs. Idempotent and
  /// error-tolerant — a blob that can't be placed now is retried on the next
  /// launch; the ones that worked stay worked. Returns how many were placed
  /// in this pass.
  Future<int> remapRestoredMedia(FieldNotesDb db) async {
    if (!hasPendingMediaRemap && !hasStagedRestore) return 0;
    final blobDir = Directory(p.join(_staging.path, 'media'));
    if (!blobDir.existsSync()) {
      _finishRemap();
      return 0;
    }
    final destDir = Directory(p.join(docsDir.path, 'media', 'restored'))
      ..createSync(recursive: true);

    final rows = await (db.select(
      db.media,
    )..where((m) => m.sha256.isNotNull())).get();
    var remapped = 0;
    var failed = 0;
    for (final m in rows) {
      try {
        if (m.localPath != null && File(m.localPath!).existsSync()) continue;
        final blob = File(p.join(blobDir.path, '${m.sha256}.bin'));
        if (!blob.existsSync()) continue;
        final dest = p.join(destDir.path, '${m.id}.jpg');
        if (!File(dest).existsSync()) blob.copySync(dest);
        await (db.update(db.media)..where((x) => x.id.equals(m.id))).write(
          MediaCompanion(
            localPath: Value(dest),
            thumbPath: Value(dest),
            updatedAt: Value(nowUtcIso()),
          ),
        );
        remapped++;
      } catch (_) {
        failed++;
      }
    }
    if (failed == 0) _finishRemap();
    return remapped;
  }

  void _finishRemap() {
    // Staging served its purpose.
    if (_staging.existsSync()) {
      try {
        _staging.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
