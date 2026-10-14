import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../services/diag.dart';
import '../services/field_network.dart';
import 'target.dart';

/// The Field Notes relay (D-031, docs/RELAY-DESIGN.md): the commercial
/// carrier. One property's store on the relay, spoken to as a
/// [BackupTarget] — the same layout, the same sealed bytes the Drive
/// folder holds; the relay keeps ciphertext and knows only who is in the
/// property.
class RelayTarget implements BackupTarget {
  RelayTarget({
    required this.baseUrl,
    required this.propertyId,
    required this.token,
    http.Client? client,
  }) : _net = FieldNetwork.forClient(client);

  /// Where properties go unless prefs say otherwise. Set once deployed.
  static const defaultBaseUrl = 'https://relay.fieldnotes.app';

  /// The default relay is on the allowlist; any other address is one the
  /// user typed into Settings, and is logged as such.
  static EgressPurpose purposeFor(String baseUrl) =>
      Uri.tryParse(baseUrl)?.host == Uri.parse(defaultBaseUrl).host
      ? EgressPurpose.relay
      : EgressPurpose.relayCustom;

  /// `https://relay.example` — no trailing slash.
  final String baseUrl;
  final String propertyId;

  /// This member's bearer token for this property.
  final String token;
  final FieldNetwork _net;

  @override
  String get description => 'Field Notes relay';

  Map<String, String> get _auth => {'authorization': 'Bearer $token'};

  EgressPurpose get _purpose => purposeFor(baseUrl);

  Uri _object(String path) => Uri.parse(
    '$baseUrl/v1/properties/$propertyId/store/'
    '${path.split('/').map(Uri.encodeComponent).join('/')}',
  );

  @override
  Future<bool> exists(String path) async {
    final res = await _net.head(_object(path), _purpose, headers: _auth);
    if (res.statusCode == 200) return true;
    if (res.statusCode == 404) return false;
    throw RelayException.of(res.statusCode, res.body);
  }

  @override
  Future<Uint8List> read(String path) async {
    final res = await _net.get(_object(path), _purpose, headers: _auth);
    if (res.statusCode != 200) {
      throw RelayException.of(res.statusCode, res.body);
    }
    return res.bodyBytes;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final res = await _net.put(
      _object(path),
      _purpose,
      headers: {..._auth, 'content-type': 'application/octet-stream'},
      body: bytes,
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw RelayException.of(res.statusCode, res.body);
    }
  }

  @override
  Future<List<String>> list(String prefix) async {
    final res = await _net.get(
      Uri.parse('$baseUrl/v1/properties/$propertyId/store')
          .replace(queryParameters: {'prefix': prefix}),
      _purpose,
      headers: _auth,
    );
    if (res.statusCode != 200) {
      throw RelayException.of(res.statusCode, res.body);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['names'] as List).cast<String>();
  }

  @override
  Future<void> delete(String path) async {
    final res = await _net.delete(_object(path), _purpose, headers: _auth);
    if (res.statusCode != 200 &&
        res.statusCode != 204 &&
        res.statusCode != 404) {
      throw RelayException.of(res.statusCode, res.body);
    }
  }

  void close() => _net.close();
}

/// What a device holds after creating or joining a property on the relay.
class RelayMembership {
  const RelayMembership({
    required this.propertyId,
    required this.propertyName,
    required this.memberToken,
    required this.role,
    this.badgeName,
  });

  final String propertyId;
  final String propertyName;
  final String memberToken;

  /// owner | editor | viewer.
  final String role;

  /// The organization's badge, when the property belongs to one (D-030).
  final String? badgeName;

  factory RelayMembership.fromJson(Map<String, dynamic> j) => RelayMembership(
    propertyId: j['property']['id'] as String,
    propertyName: j['property']['name'] as String,
    memberToken: j['member_token'] as String,
    role: j['role'] as String,
    badgeName: (j['badge'] as Map?)?['name'] as String?,
  );
}

/// One row of the members registry — attribution's source of names.
class RelayMember {
  const RelayMember({
    required this.id,
    required this.displayName,
    required this.role,
    this.email,
    this.deviceIds = const [],
  });
  final String id;
  final String displayName;
  final String role;
  final String? email;
  final List<String> deviceIds;

  factory RelayMember.fromJson(Map<String, dynamic> j) => RelayMember(
    id: j['id'] as String,
    displayName: j['display_name'] as String,
    role: j['role'] as String,
    email: j['email'] as String?,
    deviceIds: ((j['devices'] as List?) ?? const []).cast<String>(),
  );
}

/// Seats and badge as the relay reports them for a property.
class RelayPropertyInfo {
  const RelayPropertyInfo({
    required this.seatsUsed,
    required this.seatsAllowed,
    this.badgeName,
    this.organization,
  });
  final int seatsUsed;
  final int seatsAllowed;
  final String? badgeName;
  final String? organization;

  factory RelayPropertyInfo.fromJson(Map<String, dynamic> j) =>
      RelayPropertyInfo(
        seatsUsed: j['seats']['used'] as int,
        seatsAllowed: j['seats']['allowed'] as int,
        badgeName: (j['badge'] as Map?)?['name'] as String?,
        organization: (j['organization'] as Map?)?['name'] as String?,
      );
}

/// The control plane: creating and joining properties, the members
/// registry, seats. Everything here is metadata; the store is [RelayTarget].
class RelayClient {
  RelayClient({required this.baseUrl, http.Client? client})
    : _net = FieldNetwork.forClient(client);

  final String baseUrl;
  final FieldNetwork _net;

  EgressPurpose get _purpose => RelayTarget.purposeFor(baseUrl);

  Map<String, String> _headers(String? token) => {
    'content-type': 'application/json',
    if (token != null) 'authorization': 'Bearer $token',
  };

  Future<Map<String, dynamic>> _json(http.Response res) async {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw RelayException.of(res.statusCode, res.body);
    }
    return res.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// The owner puts a property on the relay under its own local id, so a
  /// joining device's pulled `properties` row and its store agree.
  Future<RelayMembership> createProperty({
    required String propertyId,
    required String name,
    required String displayName,
    required String deviceId,
    String? deviceLabel,
    String? organizationKey,
  }) async {
    final res = await _net.post(
      Uri.parse('$baseUrl/v1/properties'),
      _purpose,
      headers: _headers(null),
      body: jsonEncode({
        'id': propertyId,
        'name': name,
        'display_name': displayName,
        'device_id': deviceId,
        'device_label': ?deviceLabel,
        'org_key': ?organizationKey,
      }),
    );
    return RelayMembership.fromJson(await _json(res));
  }

  /// A code the owner hands over. The relay refuses one that would seat
  /// more people than the property may hold.
  Future<({String code, String expiresAt})> createJoinCode({
    required String propertyId,
    required String token,
    String role = 'editor',
    String? email,
    Duration ttl = const Duration(days: 7),
  }) async {
    final res = await _net.post(
      Uri.parse('$baseUrl/v1/properties/$propertyId/join-codes'),
      _purpose,
      headers: _headers(token),
      body: jsonEncode({
        'role': role,
        'email': ?email,
        'ttl_seconds': ttl.inSeconds,
      }),
    );
    final j = await _json(res);
    return (code: j['code'] as String, expiresAt: j['expires_at'] as String);
  }

  Future<RelayMembership> join({
    required String code,
    required String displayName,
    required String deviceId,
    String? email,
    String? deviceLabel,
  }) async {
    final res = await _net.post(
      Uri.parse('$baseUrl/v1/join'),
      _purpose,
      headers: _headers(null),
      body: jsonEncode({
        'code': code,
        'display_name': displayName,
        'device_id': deviceId,
        'email': ?email,
        'device_label': ?deviceLabel,
      }),
    );
    return RelayMembership.fromJson(await _json(res));
  }

  /// Put an existing property under an organization's licence (owner).
  Future<RelayPropertyInfo> attachOrganization({
    required String propertyId,
    required String token,
    required String organizationKey,
  }) async {
    final res = await _net.post(
      Uri.parse('$baseUrl/v1/properties/$propertyId/organization'),
      _purpose,
      headers: _headers(token),
      body: jsonEncode({'org_key': organizationKey}),
    );
    return RelayPropertyInfo.fromJson(await _json(res));
  }

  Future<RelayPropertyInfo> property({
    required String propertyId,
    required String token,
  }) async {
    final res = await _net.get(
      Uri.parse('$baseUrl/v1/properties/$propertyId'),
      _purpose,
      headers: _headers(token),
    );
    return RelayPropertyInfo.fromJson(await _json(res));
  }

  Future<List<RelayMember>> members({
    required String propertyId,
    required String token,
  }) async {
    final res = await _net.get(
      Uri.parse('$baseUrl/v1/properties/$propertyId/members'),
      _purpose,
      headers: _headers(token),
    );
    final j = await _json(res);
    return [
      for (final m in (j['members'] as List).cast<Map<String, dynamic>>())
        RelayMember.fromJson(m),
    ];
  }

  Future<void> removeMember({
    required String propertyId,
    required String token,
    required String memberId,
  }) async {
    final res = await _net.delete(
      Uri.parse('$baseUrl/v1/properties/$propertyId/members/$memberId'),
      _purpose,
      headers: _headers(token),
    );
    await _json(res);
  }

  /// Register or refresh this device under its member — the relay's
  /// "last seen", and the device ids attribution maps to names.
  Future<void> registerDevice({
    required String propertyId,
    required String token,
    required String deviceId,
    String? label,
  }) async {
    final res = await _net.post(
      Uri.parse('$baseUrl/v1/properties/$propertyId/devices'),
      _purpose,
      headers: _headers(token),
      body: jsonEncode({'device_id': deviceId, 'label': ?label}),
    );
    await _json(res);
  }

  void close() => _net.close();
}

/// A relay answer that is a sentence for a person, not a stack trace.
class RelayException implements Exception {
  const RelayException(this.status, this.message);
  final int status;
  final String message;

  /// Removed from the property, or the token is stale.
  bool get unauthorized => status == 401;

  /// The seat past the licence, or a role that may not do this.
  bool get forbidden => status == 403;

  factory RelayException.of(int status, String body) {
    String? detail;
    try {
      detail = (jsonDecode(body) as Map)['error'] as String?;
    } catch (e, st) {
      Diag.report(e, st, where: 'RelayException.of');
    }
    return RelayException(status, switch (status) {
      401 =>
        detail ??
            'This device is no longer a member of the property — ask the '
                'owner for a new join code.',
      403 =>
        detail ??
            'The relay refused this: the property may be at its seat '
                'limit, or this role may not write.',
      404 => detail ?? 'Not found on the relay.',
      413 => detail ?? 'Too large for the relay.',
      >= 500 => detail ?? 'The relay is having trouble ($status). Try later.',
      _ => detail ?? 'Relay error $status.',
    });
  }

  @override
  String toString() => message;
}
