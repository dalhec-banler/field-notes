import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../backup/backup_engine.dart';
import '../backup/key_cache.dart';
import '../backup/keyring.dart';
import '../backup/relay_target.dart';
import '../db/database.dart';
import '../services/app_prefs.dart';
import 'oplog.dart';
import 'shared_properties.dart';

/// Sharing a property through the relay (D-031): the owner seals it with
/// a new keyring and puts it on the relay; members join with a code and
/// the passphrase. The relay never sees the passphrase or the key — only
/// the envelope, which is safe in the clear.
class SharingService {
  SharingService(
    this.db,
    this.prefs,
    this.log, {
    this._client,
    BackupKeyCache Function(String propertyId)? keyCache,
  }) : _keyCache = keyCache ?? BackupKeyCache.forSharedProperty;

  final FieldNotesDb db;
  final AppPrefs prefs;
  final OpLog log;
  final http.Client? _client;
  final BackupKeyCache Function(String propertyId) _keyCache;

  /// Where properties go unless prefs say otherwise. Set once deployed.
  static const defaultRelayUrl = 'https://relay.fieldnotes.app';
  String get relayUrl => prefs.get<String>('relay_url') ?? defaultRelayUrl;

  static const _manifest = '${BackupEngine.root}/manifest.json';

  RelayClient _relay(String url) => RelayClient(baseUrl: url, client: _client);

  RelayTarget _target(SharedProperty s) => RelayTarget(
    baseUrl: s.relayUrl,
    propertyId: s.propertyId,
    token: s.memberToken,
    client: _client,
  );

  /// Owner: put [property] on the relay under a fresh keyring. Show the
  /// recovery phrase exactly once. The property's rows go up on the next
  /// sync; nothing is exchanged here but the envelope.
  Future<({SharedProperty shared, String recoveryPhrase})> share({
    required Property property,
    required String passphrase,
    required String displayName,
    String? email,
    String? organizationKey,
    String? deviceLabel,
  }) async {
    final keyring = await BackupKeyring.create(passphrase);
    final m = await _relay(relayUrl).createProperty(
      propertyId: property.id,
      name: property.name,
      displayName: displayName,
      deviceId: log.deviceId,
      deviceLabel: deviceLabel,
      organizationKey: organizationKey,
    );
    final s = SharedProperty(
      propertyId: property.id,
      name: property.name,
      relayUrl: relayUrl,
      memberToken: m.memberToken,
      role: m.role,
      badgeName: m.badgeName,
    );
    final envelope = {
      'app': 'field_notes',
      'format': 1,
      'shared': true,
      ...keyring.envelopeFields,
      'created_at': nowUtcIso(),
    };
    await _target(
      s,
    ).write(_manifest, Uint8List.fromList(utf8.encode(jsonEncode(envelope))));
    await _keyCache(property.id).write(await keyring.dataKeyBytes());
    prefs.putSharedProperty(s);
    return (shared: s, recoveryPhrase: keyring.recoveryPhrase!);
  }

  /// Owner: a code to hand over — one seat, one use, a week.
  Future<({String code, String expiresAt})> invite(
    SharedProperty s, {
    String role = 'editor',
    String? email,
  }) => _relay(s.relayUrl).createJoinCode(
    propertyId: s.propertyId,
    token: s.memberToken,
    role: role,
    email: email,
  );

  /// Member: take a seat with a code, then try the passphrase against the
  /// property's envelope. Joining and unlocking are separate facts: the
  /// seat is real once the code is spent, and a wrong passphrase is
  /// retried from the property's sync screen, not by burning another code.
  Future<({SharedProperty shared, bool unlocked})> join({
    required String code,
    required String passphrase,
    required String displayName,
    String? email,
    String? deviceLabel,
    String? relayUrl,
  }) async {
    final url = relayUrl ?? this.relayUrl;
    final m = await _relay(url).join(
      code: code,
      displayName: displayName,
      deviceId: log.deviceId,
      email: email,
      deviceLabel: deviceLabel,
    );
    final s = SharedProperty(
      propertyId: m.propertyId,
      name: m.propertyName,
      relayUrl: url,
      memberToken: m.memberToken,
      role: m.role,
      badgeName: m.badgeName,
    );
    prefs.putSharedProperty(s);
    var unlocked = false;
    try {
      final fields = jsonDecode(
        utf8.decode(await _target(s).read(_manifest)),
      ) as Map<String, dynamic>;
      final keyring = await BackupKeyring.unlockWithPassphrase(
        fields,
        passphrase,
      );
      await _keyCache(s.propertyId).write(await keyring.dataKeyBytes());
      unlocked = true;
    } catch (_) {
      // Wrong passphrase, or the owner has not written the envelope yet.
    }
    return (shared: s, unlocked: unlocked);
  }

  Future<RelayPropertyInfo> info(SharedProperty s) =>
      _relay(s.relayUrl)
          .property(propertyId: s.propertyId, token: s.memberToken);

  Future<List<RelayMember>> members(SharedProperty s) =>
      _relay(s.relayUrl)
          .members(propertyId: s.propertyId, token: s.memberToken);

  Future<void> removeMember(SharedProperty s, String memberId) =>
      _relay(s.relayUrl).removeMember(
        propertyId: s.propertyId,
        token: s.memberToken,
        memberId: memberId,
      );

  /// Owner: put the property under an organization's key — more seats,
  /// and the badge.
  Future<SharedProperty> attachOrganization(
    SharedProperty s,
    String organizationKey,
  ) async {
    final info = await _relay(s.relayUrl).attachOrganization(
      propertyId: s.propertyId,
      token: s.memberToken,
      organizationKey: organizationKey,
    );
    final updated = s.copyWith(badgeName: info.badgeName);
    prefs.putSharedProperty(updated);
    return updated;
  }

  /// This device stops exchanging the property. The local copy stays; the
  /// seat stays until the owner removes it.
  Future<void> leave(SharedProperty s) async {
    prefs.removeSharedProperty(s.propertyId);
    await _keyCache(s.propertyId).clear();
  }
}
