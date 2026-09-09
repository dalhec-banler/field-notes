import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart';

import '../backup/backup_crypto.dart';
import '../backup/backup_engine.dart';
import '../backup/backup_service.dart';
import '../backup/drive_auth.dart';
import '../backup/drive_target.dart';
import '../backup/key_cache.dart';
import '../backup/keyring.dart';
import '../backup/relay_target.dart';
import '../backup/target.dart';
import '../db/database.dart';
import '../services/app_prefs.dart';
import '../services/desk.dart';
import '../services/media_store.dart';
import '../services/network_policy.dart';
import 'oplog.dart';
import 'shared_properties.dart';

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
    this.problems = const [],
  });
  final int pushed, applied, skipped, mediaUp, mediaDown, mediaWaiting;

  /// One line for a person. Set on failure; also set for "nothing to do".
  final String? note;
  final bool failed;

  /// A shared property that could not be exchanged this time, each as a
  /// sentence naming it (D-031). The rest of the run still counts.
  final List<String> problems;

  String get summary {
    if (note != null) return note!;
    final bits = <String>[
      if (pushed > 0) '$pushed sent',
      if (applied > 0) '$applied received',
      if (mediaUp > 0) '$mediaUp photos up',
      if (mediaDown > 0) '$mediaDown photos down',
      if (mediaWaiting > 0) '$mediaWaiting photos waiting for Wi-Fi',
      ...problems,
    ];
    return bits.isEmpty ? 'Up to date' : bits.join(' · ');
  }

  SyncReport operator +(SyncReport o) => SyncReport(
    pushed: pushed + o.pushed,
    applied: applied + o.applied,
    skipped: skipped + o.skipped,
    mediaUp: mediaUp + o.mediaUp,
    mediaDown: mediaDown + o.mediaDown,
    mediaWaiting: mediaWaiting + o.mediaWaiting,
    problems: [...problems, ...o.problems],
  );
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
    BackupTarget Function(SharedProperty)? openSharedTarget,
    Future<BackupCipher?> Function(
      SharedProperty,
      BackupTarget,
      Future<String?> Function()? askPassphrase,
      void Function(String)? onStatus,
    )?
    openSharedCipher,
  }) : _backup = backup ?? BackupService(db),
       _openTarget = openTarget,
       _openCipher = openCipher,
       _mediaAllowed = mediaAllowed,
       _media = media ?? MediaStore(db),
       _openSharedTarget = openSharedTarget,
       _openSharedCipher = openSharedCipher;

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
  final BackupTarget Function(SharedProperty)? _openSharedTarget;
  final Future<BackupCipher?> Function(
    SharedProperty,
    BackupTarget,
    Future<String?> Function()? askPassphrase,
    void Function(String)? onStatus,
  )?
  _openSharedCipher;

  static const autoInterval = Duration(minutes: 15);

  /// One sync at a time, process-wide.
  static bool _busy = false;
  static bool get busy => _busy;

  /// Something to exchange with: Drive connected with the switch on, or a
  /// property shared through the relay (D-031).
  bool get configured => driveConfigured || prefs.sharedProperties.isNotEmpty;
  bool get driveConfigured => prefs.driveEmail != null && prefs.driveSync;

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
  ///
  /// The keyring is the PHONE's (D-028): its salts and wrapped keys ride
  /// in the plaintext envelope of Drive's manifest, which is how the desk
  /// unlocked the copy it restored — and the desk never kept those
  /// fields, its own local backup being plain. So: this device's config
  /// if it has a keyring, else the envelope in the folder; the cached
  /// data key if there is one, else the passphrase, asked once and
  /// cached. Returns the cipher, or the sentence to show instead.
  Future<(BackupCipher?, String?)> _cipher(
    BackupTarget target,
    Future<String?> Function()? askPassphrase,
    void Function(String)? onStatus,
  ) async {
    if (_openCipher != null) {
      return (await _openCipher(askPassphrase, onStatus), null);
    }
    final config = await _backup.loadConfigOrNull();
    if (config == null) {
      return (null, 'Backup settings file is damaged — see Settings.');
    }
    Map<String, dynamic> fields = config;
    if (fields['wrap_pass'] == null) {
      const path = '${BackupEngine.root}/manifest.json';
      if (!await target.exists(path)) {
        return (
          null,
          'No backup in Drive yet — back the phone up to Drive first.',
        );
      }
      try {
        fields = jsonDecode(
          utf8.decode(await target.read(path)),
        ) as Map<String, dynamic>;
      } catch (e) {
        return (null, 'Could not read the backup envelope in Drive: $e');
      }
      if (fields['wrap_pass'] == null) {
        return (
          null,
          'Sync needs the Drive backup to be encrypted — set a passphrase '
              'under Backup on the phone, back up, then sync.',
        );
      }
    }
    final cache = BackupKeyCache();
    final cached = await cache.read();
    if (cached != null) {
      return (BackupKeyring.fromCachedKey(cached, fields).cipher, null);
    }
    final passphrase = await askPassphrase?.call();
    if (passphrase == null || passphrase.isEmpty) {
      return (null, 'Sync needs the backup passphrase once — open Sync.');
    }
    onStatus?.call('Unlocking…');
    try {
      final keyring = await BackupKeyring.unlockWithPassphrase(
        fields,
        passphrase,
      );
      await cache.write(await keyring.dataKeyBytes());
      return (keyring.cipher, null);
    } catch (_) {
      return (null, 'Wrong passphrase.');
    }
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
    try {
      // One human's devices through the Drive app folder (D-028) …
      SyncReport? own;
      if (driveConfigured) {
        own = await _syncOwnDevices(interactive, askPassphrase, onStatus);
      }
      // … then each property shared through the relay (D-031), in its own
      // scope with its own key. One folder failing never stops the next.
      final shared = <SyncReport>[];
      for (final s in prefs.sharedProperties) {
        shared.add(await _syncShared(s, interactive, askPassphrase, onStatus));
      }
      if (shared.isEmpty) {
        return await _done(
          own ?? const SyncReport(note: 'Nothing is set up to sync.'),
        );
      }
      var total = own == null || own.failed
          ? SyncReport(problems: [if (own != null) own.summary])
          : own;
      for (final r in shared) {
        total = total + r;
      }
      if (own != null && !own.failed || shared.any((r) => !r.failed)) {
        await log.setMeta('last_sync_at', nowUtcIso());
      }
      return await _done(total);
    } finally {
      _busy = false;
    }
  }

  Future<SyncReport> _syncOwnDevices(
    bool interactive,
    Future<String?> Function()? askPassphrase,
    void Function(String)? onStatus,
  ) async {
    BackupTarget? target;
    try {
      onStatus?.call('Connecting to Drive…');
      target = await _target(interactive: interactive);
      if (target == null) {
        return const SyncReport(
          note: 'Drive is not connected — open Sync and connect.',
          failed: true,
        );
      }
      final (cipher, why) = await _cipher(target, askPassphrase, onStatus);
      if (cipher == null) return SyncReport(note: why, failed: true);
      final report = await _cycle(
        target,
        cipher,
        const SyncScope.all(),
        onStatus: onStatus,
      );
      await log.setMeta('last_sync_at', nowUtcIso());
      return report;
    } catch (e) {
      return SyncReport(note: 'Sync failed: $e', failed: true);
    } finally {
      if (target is DriveTarget) target.close();
    }
  }

  /// A relay leg. Unauthorized or forbidden pauses the property so the
  /// automatic runner stops knocking; opening its screen resumes it.
  Future<SyncReport> _syncShared(
    SharedProperty s,
    bool interactive,
    Future<String?> Function()? askPassphrase,
    void Function(String)? onStatus,
  ) async {
    final scope = SyncScope.property(s.propertyId);
    Future<SyncReport> finish(SyncReport r) async {
      await log.setMeta(scope.metaKey('last_sync_note'), r.summary);
      if (!r.failed)
        await log.setMeta(scope.metaKey('last_sync_at'), nowUtcIso());
      return r;
    }

    if (s.paused && !interactive) {
      return finish(
        SyncReport(
          failed: true,
          problems: ['${s.name}: paused — open it to try again'],
        ),
      );
    }
    BackupTarget? target;
    try {
      onStatus?.call('${s.name}: connecting…');
      target =
          _openSharedTarget?.call(s) ??
          RelayTarget(
            baseUrl: s.relayUrl,
            propertyId: s.propertyId,
            token: s.memberToken,
          );
      final cipher = _openSharedCipher != null
          ? await _openSharedCipher(s, target, askPassphrase, onStatus)
          : await _sharedCipher(s, target, askPassphrase, onStatus);
      if (cipher == null) {
        return await finish(
          SyncReport(
            failed: true,
            problems: ['${s.name}: needs its passphrase once — open it'],
          ),
        );
      }
      final r = await _cycle(
        target,
        cipher,
        scope,
        propertyId: s.propertyId,
        canWrite: s.canWrite,
        onStatus: (m) => onStatus?.call('${s.name}: $m'),
      );
      if (s.paused) prefs.putSharedProperty(s.copyWith(paused: false));
      return await finish(r);
    } on RelayException catch (e) {
      if (e.unauthorized || e.forbidden) {
        prefs.putSharedProperty(s.copyWith(paused: true));
      }
      return finish(
        SyncReport(failed: true, problems: ['${s.name}: ${e.message}']),
      );
    } catch (e) {
      return finish(SyncReport(failed: true, problems: ['${s.name}: $e']));
    } finally {
      if (target is RelayTarget) target.close();
    }
  }

  /// A shared property is sealed with its own keyring, whose envelope is
  /// the manifest in its store; the key is cached per property.
  Future<BackupCipher?> _sharedCipher(
    SharedProperty s,
    BackupTarget target,
    Future<String?> Function()? askPassphrase,
    void Function(String)? onStatus,
  ) async {
    final cache = BackupKeyCache.forSharedProperty(s.propertyId);
    const path = '${BackupEngine.root}/manifest.json';
    if (!await target.exists(path)) {
      throw StateError('the property has no keyring on the relay yet');
    }
    final fields = jsonDecode(
      utf8.decode(await target.read(path)),
    ) as Map<String, dynamic>;
    final cached = await cache.read();
    if (cached != null) {
      return BackupKeyring.fromCachedKey(cached, fields).cipher;
    }
    final passphrase = await askPassphrase?.call();
    if (passphrase == null || passphrase.isEmpty) return null;
    onStatus?.call('Unlocking…');
    try {
      final keyring = await BackupKeyring.unlockWithPassphrase(
        fields,
        passphrase,
      );
      await cache.write(await keyring.dataKeyBytes());
      return keyring.cipher;
    } catch (_) {
      throw StateError('wrong passphrase');
    }
  }

  /// One exchange with one store: push, media up, pull, media down.
  Future<SyncReport> _cycle(
    BackupTarget target,
    BackupCipher cipher,
    SyncScope scope, {
    String? propertyId,
    bool canWrite = true,
    void Function(String)? onStatus,
  }) async {
    // 1. Push, in bounded batches (a viewer has nothing it may send).
    var pushed = 0;
    if (canWrite) {
      onStatus?.call('Sending changes…');
      while (true) {
        final n = await log.push(target, cipher: cipher, scope: scope);
        pushed += n;
        if (n == 0) break;
      }
    }

    // 2. Media up: whatever the store lacks, on a network that allows it.
    final bulk = await _bulkOk();
    var mediaUp = 0;
    var waiting = 0;
    if (bulk && canWrite) {
      onStatus?.call('Uploading photos…');
      mediaUp = await _pushMedia(
        target,
        cipher,
        onStatus,
        propertyId: propertyId,
      );
    }

    // 3. Pull and apply.
    onStatus?.call('Receiving changes…');
    final pulled = await log.pull(target, cipher: cipher, scope: scope);

    // 4. Media down for rows this device has no file for.
    var mediaDown = 0;
    final missing = await _mediaWithoutFile(propertyId: propertyId);
    if (missing.isNotEmpty) {
      if (bulk) {
        onStatus?.call('Downloading photos…');
        mediaDown = await _pullMedia(target, cipher, missing, onStatus);
        waiting = missing.length - mediaDown;
      } else {
        waiting = missing.length;
      }
    }

    return SyncReport(
      pushed: pushed,
      applied: pulled.applied,
      skipped: pulled.skipped,
      mediaUp: mediaUp,
      mediaDown: mediaDown,
      mediaWaiting: waiting,
    );
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
    void Function(String)? onStatus, {
    String? propertyId,
  }) async {
    final q = db.select(db.media)
      ..where((m) => m.deletedAt.isNull())
      ..where((m) => m.sha256.isNotNull())
      ..where((m) => m.localPath.isNotNull());
    // A shared store carries one property's photos and no others (D-030).
    if (propertyId != null) q.where((m) => m.propertyId.equals(propertyId));
    final rows = await q.get();
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

  Future<List<MediaData>> _mediaWithoutFile({String? propertyId}) async {
    final q = db.select(db.media)
      ..where((m) => m.deletedAt.isNull())
      ..where((m) => m.sha256.isNotNull());
    if (propertyId != null) q.where((m) => m.propertyId.equals(propertyId));
    final rows = await q.get();
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

/// A cipher for tests and plain stores: the keyring's, when there is one.
BackupCipher cipherFromKeyBytes(List<int> key, Map<String, dynamic> config) =>
    BackupKeyring.fromCachedKey(key, config).cipher;

/// The blob path helper, exposed for tests that seed a store by hand.
String syncBlobPath(BackupCipher cipher, String blobName) =>
    '${BackupEngine.root}/blobs/${blobName.substring(0, 2)}/$blobName${cipher.ext}';
