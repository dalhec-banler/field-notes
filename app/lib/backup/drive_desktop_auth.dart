import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'drive_target.dart';

/// Where the desk keeps its Drive grant. The keychain in the app; memory
/// in tests.
abstract class DriveTokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain first. An ad-hoc-signed sandboxed build (no Apple team yet)
/// is refused by the keychain with errSecMissingEntitlement (-34018); then
/// the grant lives in a file inside the app's own sandbox container — the
/// same protection the database itself has. Signing with a team and a
/// keychain entitlement moves it back into the keychain, no code change.
class SecureDriveTokenStore implements DriveTokenStore {
  SecureDriveTokenStore() : _s = const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  bool _keychainBroken = false;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/drive_desktop_grant.json');
  }

  Future<Map<String, String>> _readFile() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return {};
      return (jsonDecode(await f.readAsString()) as Map).map(
        (k, v) => MapEntry(k as String, v as String),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeFile(Map<String, String> m) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(m), flush: true);
  }

  @override
  Future<String?> read(String key) async {
    if (!_keychainBroken) {
      try {
        final v = await _s.read(key: key);
        if (v != null) return v;
      } catch (_) {
        _keychainBroken = true;
      }
    }
    return (await _readFile())[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (!_keychainBroken) {
      try {
        await _s.write(key: key, value: value);
        return;
      } catch (_) {
        _keychainBroken = true;
      }
    }
    final m = await _readFile();
    m[key] = value;
    await _writeFile(m);
  }

  @override
  Future<void> delete(String key) async {
    if (!_keychainBroken) {
      try {
        await _s.delete(key: key);
      } catch (_) {
        _keychainBroken = true;
      }
    }
    final m = await _readFile();
    if (m.remove(key) != null) await _writeFile(m);
  }
}

class MemoryDriveTokenStore implements DriveTokenStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

/// Google sign-in for the desk (D-024): the installed-app flow. The desk
/// opens the system browser on Google's consent page, listens once on a
/// loopback port for the redirect, and trades the code for tokens with
/// PKCE. The refresh token lives in the keychain; Google is only ever
/// contacted from [accessToken], never at launch.
///
/// The client is a **Desktop app** OAuth client in the same Cloud project
/// as the phone's. Google's own guidance: for installed apps the "secret"
/// cannot be kept secret and is not treated as one — it identifies the app,
/// it authorises nothing without the user's consent in the browser.
class DriveDesktopAuth {
  DriveDesktopAuth({
    http.Client? client,
    DriveTokenStore? store,
    Future<bool> Function(Uri)? launch,
    this.timeout = const Duration(minutes: 5),
  }) : _client = client ?? http.Client(),
       _store = store ?? SecureDriveTokenStore(),
       _launch = launch ?? _openBrowser;

  static final instance = DriveDesktopAuth();

  static const clientId =
      '447000916304-du33tlvdvovbi6l37s02ltf1sme9j1kk.apps.googleusercontent.com';
  static const clientSecret = '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';
  static const scopes = [DriveTarget.scope, 'openid', 'email'];

  static const _authUrl = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenUrl = 'https://oauth2.googleapis.com/token';
  static const _revokeUrl = 'https://oauth2.googleapis.com/revoke';
  static const _kRefresh = 'drive_desktop_refresh_token';
  static const _kEmail = 'drive_desktop_email';

  final http.Client _client;
  final DriveTokenStore _store;
  final Future<bool> Function(Uri) _launch;
  final Duration timeout;

  String? _accessToken;
  DateTime? _expiresAt;
  String? _email;

  static Future<bool> _openBrowser(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  /// The address of the connected account, remembered locally.
  Future<String?> get email async => _email ??= await _store.read(_kEmail);

  Future<bool> get isConnected async => (await _store.read(_kRefresh)) != null;

  /// A Drive token. Non-interactive: reuse or refresh, else null.
  /// Interactive: the browser consent — only ever from a Connect button.
  Future<String?> accessToken({required bool interactive}) async {
    final now = DateTime.now();
    if (_accessToken != null &&
        _expiresAt != null &&
        now.isBefore(_expiresAt!.subtract(const Duration(minutes: 1)))) {
      return _accessToken;
    }
    final refresh = await _store.read(_kRefresh);
    if (refresh != null) {
      final ok = await _exchange({
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      });
      if (ok) return _accessToken;
      // A revoked or expired grant: forget it so the next tap reconnects.
      await _store.delete(_kRefresh);
    }
    if (!interactive) return null;
    await _consent();
    return _accessToken;
  }

  Future<void> disconnect() async {
    final refresh = await _store.read(_kRefresh);
    if (refresh != null) {
      try {
        await _client
            .post(Uri.parse(_revokeUrl), body: {'token': refresh})
            .timeout(const Duration(seconds: 15));
      } catch (_) {}
    }
    await _store.delete(_kRefresh);
    await _store.delete(_kEmail);
    _accessToken = null;
    _expiresAt = null;
    _email = null;
  }

  // ── the installed-app flow ─────────────────────────────────────────

  Future<void> _consent() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    final verifier = _random(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _random(24);
    final uri = Uri.parse(_authUrl).replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'access_type': 'offline',
        'prompt': 'consent',
      },
    );

    final codeCompleter = Completer<String>();
    final sub = server.listen((req) async {
      final q = req.uri.queryParameters;
      final ok = q['state'] == state && q['code'] != null;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(ok ? _donePage : _failPage);
      await req.response.close();
      if (!codeCompleter.isCompleted) {
        if (ok) {
          codeCompleter.complete(q['code']!);
        } else {
          codeCompleter.completeError(
            DriveException(
              q['error'] == 'access_denied'
                  ? 'Sign-in was cancelled.'
                  : 'Sign-in did not complete (${q['error'] ?? 'no code'}).',
            ),
          );
        }
      }
    });

    try {
      if (!await _launch(uri)) {
        throw const DriveException('Could not open the browser to sign in.');
      }
      final code = await codeCompleter.future.timeout(
        timeout,
        onTimeout: () => throw const DriveException(
          'Sign-in timed out — the browser never came back.',
        ),
      );
      final ok = await _exchange({
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirect,
        'code_verifier': verifier,
      });
      if (!ok) throw const DriveException('Google refused the sign-in code.');
    } finally {
      await sub.cancel();
      await server.close(force: true);
    }
  }

  Future<bool> _exchange(Map<String, String> params) async {
    final res = await _client
        .post(
          Uri.parse(_tokenUrl),
          body: {
            'client_id': clientId,
            'client_secret': clientSecret,
            ...params,
          },
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) return false;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final token = body['access_token'] as String?;
    if (token == null) return false;
    _accessToken = token;
    _expiresAt = DateTime.now().add(
      Duration(seconds: (body['expires_in'] as num?)?.toInt() ?? 3600),
    );
    final refresh = body['refresh_token'] as String?;
    if (refresh != null) await _store.write(_kRefresh, refresh);
    final idToken = body['id_token'] as String?;
    final email = idToken == null ? null : _emailFromIdToken(idToken);
    if (email != null) {
      _email = email;
      await _store.write(_kEmail, email);
    }
    return true;
  }

  /// The id_token is a JWT; its payload names the account. We read it, we
  /// do not verify it — it came straight from Google's token endpoint over
  /// TLS and is used only as a label.
  static String? _emailFromIdToken(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      payload += '=' * ((4 - payload.length % 4) % 4);
      final map = jsonDecode(utf8.decode(base64.decode(payload))) as Map;
      return map['email'] as String?;
    } catch (_) {
      return null;
    }
  }

  static String _random(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static const _donePage =
      '<!doctype html><meta charset="utf-8">'
      '<title>Field Notes</title>'
      '<body style="font-family:Georgia,serif;background:#F7F6F2;color:#1B1813;'
      'display:flex;align-items:center;justify-content:center;height:100vh;margin:0">'
      '<div style="max-width:32em;text-align:center"><h1 style="letter-spacing:.06em">'
      'CONNECTED</h1><p>Field Notes on this computer can now use your Drive app '
      'folder. You can close this tab.</p></div></body>';
  static const _failPage =
      '<!doctype html><meta charset="utf-8">'
      '<title>Field Notes</title><body style="font-family:Georgia,serif;'
      'background:#F7F6F2;color:#1B1813;display:flex;align-items:center;'
      'justify-content:center;height:100vh;margin:0"><div style="max-width:32em;'
      'text-align:center"><h1>NOT CONNECTED</h1><p>Sign-in did not complete. '
      'Go back to Field Notes and try Connect again.</p></div></body>';
}
