import 'dart:convert';

import 'package:field_notes/backup/drive_desktop_auth.dart';
import 'package:field_notes/backup/drive_target.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The desk's Drive sign-in (D-024): the installed-app flow end to end
/// against a fake Google — consent redirect on the loopback port, PKCE
/// exchange, refresh, revoke — with nothing leaving the test.
void main() {
  String idToken(String email) {
    final payload = base64Url
        .encode(utf8.encode(jsonEncode({'email': email})))
        .replaceAll('=', '');
    return 'hdr.$payload.sig';
  }

  test('interactive: browser comes back with a code, tokens are stored',
      () async {
    final store = MemoryDriveTokenStore();
    final seen = <Map<String, String>>[];
    final client = MockClient((req) async {
      if (req.url.path == '/token') {
        final body = Uri.splitQueryString(req.body);
        seen.add(body);
        return http.Response(
            jsonEncode({
              'access_token': 'at-1',
              'refresh_token': 'rt-1',
              'expires_in': 3600,
              'id_token': idToken('austin@example.com'),
            }),
            200);
      }
      return http.Response('nope', 404);
    });
    late Uri consent;
    final auth = DriveDesktopAuth(
      client: client,
      store: store,
      launch: (uri) async {
        consent = uri;
        // The "browser": follow the redirect back with the code + state.
        final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
        final back = redirect.replace(queryParameters: {
          'code': 'the-code',
          'state': uri.queryParameters['state']!,
        });
        // Fire and forget: the real browser does not await the app.
        // ignore: unawaited_futures
        http.get(back);
        return true;
      },
    );

    final token = await auth.accessToken(interactive: true);
    expect(token, 'at-1');
    expect(consent.host, 'accounts.google.com');
    expect(consent.queryParameters['scope'], contains(DriveTarget.scope));
    expect(consent.queryParameters['code_challenge_method'], 'S256');
    expect(consent.queryParameters['redirect_uri'], startsWith('http://127.0.0.1:'));
    final exchange = seen.single;
    expect(exchange['grant_type'], 'authorization_code');
    expect(exchange['code'], 'the-code');
    expect(exchange['code_verifier'], isNotEmpty);
    expect(await store.read('drive_desktop_refresh_token'), 'rt-1');
    expect(await auth.email, 'austin@example.com');
    expect(await auth.isConnected, isTrue);
  });

  test('non-interactive: a stored refresh token is enough, no browser',
      () async {
    final store = MemoryDriveTokenStore();
    await store.write('drive_desktop_refresh_token', 'rt-old');
    var launched = false;
    final client = MockClient((req) async {
      final body = Uri.splitQueryString(req.body);
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'rt-old');
      return http.Response(
          jsonEncode({'access_token': 'at-2', 'expires_in': 3600}), 200);
    });
    final auth = DriveDesktopAuth(
        client: client,
        store: store,
        launch: (_) async {
          launched = true;
          return true;
        });
    expect(await auth.accessToken(interactive: false), 'at-2');
    expect(launched, isFalse);
    // Cached until it nears expiry: a second call makes no request.
    expect(await auth.accessToken(interactive: false), 'at-2');
  });

  test('non-interactive with no grant returns null; a dead grant is dropped',
      () async {
    final store = MemoryDriveTokenStore();
    await store.write('drive_desktop_refresh_token', 'rt-revoked');
    final client = MockClient((req) async =>
        http.Response(jsonEncode({'error': 'invalid_grant'}), 400));
    final auth = DriveDesktopAuth(
        client: client, store: store, launch: (_) async => true);
    expect(await auth.accessToken(interactive: false), isNull);
    expect(await store.read('drive_desktop_refresh_token'), isNull);
  });

  test('disconnect revokes at Google and forgets locally', () async {
    final store = MemoryDriveTokenStore();
    await store.write('drive_desktop_refresh_token', 'rt-1');
    await store.write('drive_desktop_email', 'a@b.c');
    String? revoked;
    final client = MockClient((req) async {
      if (req.url.path == '/revoke') {
        revoked = Uri.splitQueryString(req.body)['token'];
        return http.Response('', 200);
      }
      return http.Response('', 404);
    });
    final auth = DriveDesktopAuth(
        client: client, store: store, launch: (_) async => true);
    await auth.disconnect();
    expect(revoked, 'rt-1');
    expect(await auth.isConnected, isFalse);
    expect(await auth.email, isNull);
  });

  test('a redirect with the wrong state is refused', () async {
    final store = MemoryDriveTokenStore();
    final client = MockClient((req) async => http.Response('', 500));
    final auth = DriveDesktopAuth(
      client: client,
      store: store,
      timeout: const Duration(seconds: 5),
      launch: (uri) async {
        final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
        // ignore: unawaited_futures
        http.get(redirect.replace(
            queryParameters: {'code': 'x', 'state': 'forged'}));
        return true;
      },
    );
    await expectLater(
        auth.accessToken(interactive: true), throwsA(isA<DriveException>()));
    expect(await auth.isConnected, isFalse);
  });
}
