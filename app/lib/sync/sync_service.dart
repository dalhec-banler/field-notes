import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart';

import '../backup/backup_crypto.dart';
import '../backup/backup_engine.dart';
import '../backup/backup_service.dart';
import '../backup/drive_auth.dart';
import '../backup/drive_target.dart';
import '../backup/keyring.dart';
import '../backup/target.dart';
import '../db/database.dart';
import '../services/app_prefs.dart';
import '../services/desk.dart';
import '../services/media_store.dart';
import '../services/network_policy.dart';
import 'oplog.dart';

/// What one sync did.
class SyncReport {
  const SyncReport({
    this.pushed = 0,
    this.applied = 0,
    this.skipped = 0,
    this.mediaUp = 0,
    this.mediaDown = 0,
    this.mediaWaiting = 0,
    this.note,
    this.failed = false,
  });
  final int pushed, applied, skipped, mediaUp, mediaDown, mediaWaiting;

  /// One line for a person. Set on failure; also set for "nothing to do".
  final String? note;
  final bool failed;

  String get summary {
    if (note != null) return note!;
    final bits = <String>[
      if (pushed > 0) '$pushed sent',
      if (applied > 0) '$applied received',
      if (mediaUp > 0) '$mediaUp photos up',
      if (mediaDown > 0) '$mediaDown photos down',
      if (mediaWaiting > 0) '$mediaWaiting photos waiting for Wi-Fi',
    ];
    return bits.isEmpty ? 'Up to date' : bits.join(' · ');
  }
}

/// D-028: the carrier. Two-way sync of the oplog through the same Drive
/// app folder the backup already uses, sealed with the same keyring.
///
/// One cycle: push this device's new ops as sealed batches under
/// `sync/<device>/`, upload any media blob the folder lacks, pull every
/// other device's batches and apply them (the oplog's merge rule), then
/// fetch the blobs for any media row whose file this device doesn't have.
/// Media rides only on an unmetered network unless the person allowed
/// cellular (D-016); ops are tiny and always go.
///
/// Never interactive on its own: an automatic run that would need the
/// account picker or the passphrase says so and stops. The Sync screen
/// runs it interactively.
class SyncService {
  SyncService(
    this.db,
    this.prefs,
    this.log, {
    BackupService? backup,
    Future<BackupTarget?> Function({required bool interactive})? openTarget,
    Future<BackupCipher?> Function(
      Future<String?> Function()? askPassphrase,
      void Function(String)? onStatus,
    )?
    openCipher,
    Future<bool> Function()? mediaAllowed,
    MediaStore? media,
  }) : _backup = backup ?? BackupService(db),
       _openTarget = openTarget,
       _openCipher = openCipher,
       _mediaAllowed = mediaAllowed,
       _media = media ?? MediaStore(db);

  final FieldNotesDb db;
  final AppPrefs prefs;
  final OpLog log;
  final BackupService _backup;
  final Future<BackupTarget?> Function({required bool interactive})?
  _openTarget;
  final Future<BackupCipher?> Function(
    Future<String?> Function()? askPassphrase,
    void Function(String)? onStatus,
  )?
  _openCipher;
  final Future<bool> Function()? _mediaAllowed;
  final MediaStore _media;

  static const autoInterval = Duration(minutes: 15);

  /// One sync at a time, process-wide.
  static bool _busy = false;
  static bool get busy => _busy;

  /// Drive connected and the switch on.
  bool get configured => prefs.driveEmail != null && prefs.driveSync;

  Future<String?> get lastSyncAt => log.meta('last_sync_at');
  Future<String?> get lastNote => log.meta('last_sync_note');
  Future<int> get pending => log.pendingCount;

  /// Media rows this device has no file for — what a pull will fetch.
  Future<int> get mediaMissing async {
    final rows = await _mediaWithoutFile();
    return rows.length;
  }

  Future<BackupTarget?> _target({required bool interactive}) async {
    if (_openTarget != null) return _openTarget(interactive: interactive);
    final token = await DriveAuth.instance.accessToken(
      interactive: interactive,
    );
    if (token == null) return null;
    if (interactive) prefs.driveEmail = DriveAuth.instance.lastKnownEmail;
    return DriveTarget(accessToken: token);
  }

  /// The keyring's data-key cipher. Sync is never plain: a batch carries
  /// coordinates and notes, and Drive holds ciphertext only (D-026).
  Future<BackupCipher?> _cipher(
    Future<String?> Function()? askPassphrase,
    void Function(String)? onStatus,
  ) async {
    if (_openCipher != null) return _openCipher(askPassphrase, onStatus);
    final config = await _backup.loadConfigOrNull();
    if (config == null) {
      onStatus?.call('Backup settings file is damaged — see Settings.');
      return null;
    }
    if (config['wrap_pass'] == null) {
      onStatus?.call(
        'Sync needs an encrypted backup: set a passphrase under Backup first.',
      );
      return null;
    }
    // engineForTarget owns the cache-or-ask logic; the target is a
    // throwaway — only the cipher is wanted.
    final engine = await _backup.engineForTarget(
      _NullTarget(),
      askPassphrase: askPassphrase,
      onStatus: onStatus,
    );
    return engine?.cipher;
  }

  Future<bool> _bulkOk() async {
    if (_mediaAllowed != null) return _mediaAllowed();
    if (isDesk) return true;
    return await NetworkPolicy().bulkVerdict(prefs) == BulkVerdict.ok;
  }

  /// The automatic runner: on launch, on resume, on the desk's timer. It
  /// decides; it never prompts.
  Future<SyncReport?> maybeRunAutomatic() async {
    if (!configured || _busy) return null;
    final lastAttempt = DateTime.tryParse(
      await log.meta('last_sync_attempt') ?? '',
    );
    if (lastAttempt != null &&
        DateTime.now().toUtc().difference(lastAttempt) < autoInterval) {
      return null;
    }
    return sync(interactive: false);
  }

  Future<SyncReport> sync({
    required bool interactive,
    Future<String?> Function()? askPassphrase,
    void Function(String)? onStatus,
  }) async {
    if (_busy) return const SyncReport(note: 'Already syncing.');
    _busy = true;
    await log.setMeta('last_sync_attempt', nowUtcIso());
    BackupTarget? target;
    try {
      onStatus?.call('Connecting to Drive…');
      target = await _target(interactive: interactive);
      if (target == null) {
        return await _done(
          const SyncReport(
            note: 'Drive is not connected — open Sync and connect.',
            failed: true,
          ),
        );
      }
      final cipher = await _cipher(askPassphrase, onStatus);
      if (cipher == null) {
        return await _done(
          const SyncReport(
            note: 'Sync needs the backup passphrase once — open Sync.',
            failed: true,
          ),
        );
      }

      // 1. Push, in bounded batches.
      onStatus?.call('Sending changes…');
      var pushed = 0;
      while (true) {
        final n = await log.push(target, cipher: cipher);
        pushed += n;
        if (n == 0) break;
      }

      // 2. Media up: whatever the folder lacks, on a network that allows it.
      final bulk = await _bulkOk();
      var mediaUp = 0;
      var waiting = 0;
      if (bulk) {
        onStatus?.call('Uploading photos…');
        mediaUp = await _pushMedia(target, cipher, onStatus);
      }

      // 3. Pull and apply.
      onStatus?.call('Receiving changes…');
      final pulled = await log.pull(target, cipher: cipher);

      // 4. Media down for rows this device has no file for.
      var mediaDown = 0;
      final missing = await _mediaWithoutFile();
      if (missing.isNotEmpty) {
        if (bulk) {
          onStatus?.call('Downloading photos…');
          mediaDown = await _pullMedia(target, cipher, missing, onStatus);
          waiting = missing.length - mediaDown;
        } else {
          waiting = missing.length;
        }
      }

      final report = SyncReport(
        pushed: pushed,
        applied: pulled.applied,
        skipped: pulled.skipped,
        mediaUp: mediaUp,
        mediaDown: mediaDown,
        mediaWaiting: waiting,
      );
      await log.setMeta('last_sync_at', nowUtcIso());
      return await _done(report);
    } catch (e) {
      return await _done(SyncReport(note: 'Sync failed: $e', failed: true));
    } finally {
      if (target is DriveTarget) target.close();
      _busy = false;
    }
  }

  Future<SyncReport> _done(SyncReport r) async {
    await log.setMeta('last_sync_note', r.summary);
    return r;
  }

  // ── media ────────────────────────────────────────────────────────

  static String _blobPath(BackupCipher cipher, String name) =>
      '${BackupEngine.root}/blobs/${name.substring(0, 2)}/$name${cipher.ext}';

  /// Every live media file on this device that the folder lacks. The
  /// backup writes the same blobs, so most already exist; the target's
  /// listing makes the check cheap.
  Future<int> _pushMedia(
    BackupTarget target,
    BackupCipher cipher,
    void Function(String)? onStatus,
  ) async {
    final rows =
        await (db.select(db.media)
              ..where((m) => m.deletedAt.isNull())
              ..where((m) => m.sha256.isNotNull())
              ..where((m) => m.localPath.isNotNull()))
            .get();
    var up = 0;
    for (final m in rows) {
      final f = File(m.localPath!);
      if (!f.existsSync()) continue;
      final path = _blobPath(cipher, await cipher.blobName(m.sha256!));
      if (await target.exists(path)) continue;
      await target.write(path, await cipher.seal(f.readAsBytesSync()));
      up++;
      if (up % 5 == 0) onStatus?.call('Uploading photos… $up');
    }
    return up;
  }

  Future<List<MediaData>> _mediaWithoutFile() async {
    final rows =
        await (db.select(db.media)
              ..where((m) => m.deletedAt.isNull())
              ..where((m) => m.sha256.isNotNull()))
            .get();
    return [
      for (final m in rows)
        if (m.localPath == null || !File(m.localPath!).existsSync()) m,
    ];
  }

  /// Fetch, open, check against the recorded fingerprint, file under this
  /// device's layout, and point the row at it — quietly, so the path is
  /// never pushed as an edit.
  Future<int> _pullMedia(
    BackupTarget target,
    BackupCipher cipher,
    List<MediaData> missing,
    void Function(String)? onStatus,
  ) async {
    var down = 0;
    for (final m in missing) {
      final path = _blobPath(cipher, await cipher.blobName(m.sha256!));
      if (!await target.exists(path)) continue; // not uploaded yet
      final Uint8List bytes;
      try {
        bytes = await cipher.open(await target.read(path));
      } catch (_) {
        continue;
      }
      if (sha256.convert(bytes).toString() != m.sha256) continue;
      final (local, thumb) = await _media.placeBytes(
        bytes,
        id: m.id,
        mediaType: m.mediaType,
        when: m.capturedAt ?? m.createdAt,
      );
      await log.quietly(
        () => (db.update(db.media)..where((x) => x.id.equals(m.id))).write(
          MediaCompanion(localPath: Value(local), thumbPath: Value(thumb)),
        ),
      );
      down++;
      if (down % 5 == 0) onStatus?.call('Downloading photos… $down');
    }
    return down;
  }
}

/// A target that holds nothing: for borrowing the backup service's key
/// handling without touching a store.
class _NullTarget implements BackupTarget {
  @override
  String get description => 'none';
  @override
  Future<void> delete(String path) async {}
  @override
  Future<bool> exists(String path) async => false;
  @override
  Future<List<String>> list(String prefix) async => const [];
  @override
  Future<Uint8List> read(String path) async => throw StateError('nothing here');
  @override
  Future<void> write(String path, Uint8List bytes) async {}
}

/// A cipher for tests and plain stores: the keyring's, when there is one.
BackupCipher cipherFromKeyBytes(List<int> key, Map<String, dynamic> config) =>
    BackupKeyring.fromCachedKey(key, config).cipher;

/// The blob path helper, exposed for tests that seed a store by hand.
String syncBlobPath(BackupCipher cipher, String blobName) =>
    '${BackupEngine.root}/blobs/${blobName.substring(0, 2)}/$blobName${cipher.ext}';
