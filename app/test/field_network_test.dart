import 'dart:io';

import 'package:field_notes/services/diag.dart';
import 'package:field_notes/services/field_network.dart';
import 'package:field_notes/services/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The one door out (D-038 item 4): nothing connects unless the host is on
/// the allowlist or the purpose says where else it may go, and the log that
/// says so never carries the query string.
void main() {
  /// A client that fails the test the moment anything reaches it.
  http.Client neverConnects() => MockClient((req) async {
    fail('a connection was attempted to ${req.url}');
  });

  /// A client that answers 200 and remembers what it was asked.
  (http.Client, List<http.Request>) recording() {
    final seen = <http.Request>[];
    return (
      MockClient((req) async {
        seen.add(req);
        return http.Response('ok', 200);
      }),
      seen,
    );
  }

  /// Diag lines written by FieldNetwork since the ring was cleared, oldest
  /// first (the ring itself reads newest first).
  List<String> egressLines() => [
    for (final e in Diag.entries.reversed)
      if (e.where == 'FieldNetwork') e.message,
  ];

  setUp(Diag.resetForTesting);

  group('allowlist', () {
    test('a host that is not listed is refused before any connection', () {
      final net = FieldNetwork(inner: neverConnects());
      expect(
        () => net.get(
          Uri.parse('https://evil.example.com/collect?lat=31.061847'),
          EgressPurpose.weather,
        ),
        throwsA(isA<EgressBlocked>()),
      );
    });

    test('an exact host on the list passes', () async {
      final (client, seen) = recording();
      final net = FieldNetwork(inner: client);
      final res = await net.get(
        Uri.parse('https://archive-api.open-meteo.com/v1/archive?x=1'),
        EgressPurpose.weather,
      );
      expect(res.statusCode, 200);
      expect(seen, hasLength(1));
    });

    test('a suffix entry matches subdomains and not the bare suffix', () {
      expect(FieldNetwork.hostAllowed('www.googleapis.com'), isTrue);
      expect(FieldNetwork.hostAllowed('oauth2.googleapis.com'), isTrue);
      expect(FieldNetwork.hostAllowed('googleapis.com'), isFalse);
      expect(FieldNetwork.hostAllowed('notgoogleapis.com'), isFalse);
      expect(FieldNetwork.hostAllowed('evil.com'), isFalse);
    });

    test('matching ignores case', () {
      expect(
        FieldNetwork.hostAllowed('SDMDataAccess.sc.egov.usda.gov'),
        isTrue,
      );
    });

    test('plaintext http to a public host is refused even when listed', () {
      final net = FieldNetwork(inner: neverConnects());
      expect(
        () => net.get(
          Uri.parse('http://api.inaturalist.org/v1/taxa'),
          EgressPurpose.inat,
        ),
        throwsA(isA<EgressBlocked>()),
      );
    });

    test('every method goes through the gate', () async {
      final net = FieldNetwork(inner: neverConnects());
      final bad = Uri.parse('https://evil.example.com/');
      const p = EgressPurpose.drive;
      expect(() => net.get(bad, p), throwsA(isA<EgressBlocked>()));
      expect(() => net.head(bad, p), throwsA(isA<EgressBlocked>()));
      expect(() => net.post(bad, p, body: 'x'), throwsA(isA<EgressBlocked>()));
      expect(() => net.put(bad, p, body: 'x'), throwsA(isA<EgressBlocked>()));
      expect(() => net.delete(bad, p), throwsA(isA<EgressBlocked>()));
      expect(
        () => net.send(http.Request('GET', bad), p),
        throwsA(isA<EgressBlocked>()),
      );
    });
  });

  group('local and LAN purposes', () {
    test('loopback is allowed for local, with plain http', () async {
      final (client, seen) = recording();
      final net = FieldNetwork(inner: client);
      await net.get(Uri.parse('http://127.0.0.1:5123/x'), EgressPurpose.local);
      await net.get(Uri.parse('http://localhost:5123/x'), EgressPurpose.local);
      expect(seen, hasLength(2));
    });

    test('a private address is allowed for lan and not for local', () async {
      final (client, seen) = recording();
      final net = FieldNetwork(inner: client);
      for (final host in [
        '10.0.0.7',
        '172.16.4.2',
        '192.168.1.20',
        '100.64.0.3',
      ]) {
        await net.get(Uri.parse('http://$host:51703/hello'), EgressPurpose.lan);
      }
      expect(seen, hasLength(4));
      expect(
        () => net.get(
          Uri.parse('http://192.168.1.20:51703/hello'),
          EgressPurpose.local,
        ),
        throwsA(isA<EgressBlocked>()),
      );
    });

    test('a public address is refused for lan and local', () {
      final net = FieldNetwork(inner: neverConnects());
      for (final purpose in [EgressPurpose.lan, EgressPurpose.local]) {
        expect(
          () => net.get(Uri.parse('http://8.8.8.8:51703/hello'), purpose),
          throwsA(isA<EgressBlocked>()),
        );
        expect(
          () => net.get(Uri.parse('https://example.com/hello'), purpose),
          throwsA(isA<EgressBlocked>()),
        );
      }
    });

    test('loopback and private are not allowed for an allowlist purpose', () {
      final net = FieldNetwork(inner: neverConnects());
      expect(
        () => net.get(Uri.parse('http://127.0.0.1/x'), EgressPurpose.weather),
        throwsA(isA<EgressBlocked>()),
      );
      expect(
        () => net.get(Uri.parse('http://192.168.1.2/x'), EgressPurpose.drive),
        throwsA(isA<EgressBlocked>()),
      );
    });

    test('address classes', () {
      expect(FieldNetwork.isLoopbackHost('127.0.0.1'), isTrue);
      expect(FieldNetwork.isLoopbackHost('127.5.5.5'), isTrue);
      expect(FieldNetwork.isLoopbackHost('::1'), isTrue);
      expect(FieldNetwork.isLoopbackHost('[::1]'), isTrue);
      expect(FieldNetwork.isLoopbackHost('10.0.0.1'), isFalse);
      expect(FieldNetwork.isPrivateHost('172.15.0.1'), isFalse);
      expect(FieldNetwork.isPrivateHost('172.31.255.1'), isTrue);
      expect(FieldNetwork.isPrivateHost('169.254.1.1'), isTrue);
      expect(FieldNetwork.isPrivateHost('fd12::1'), isTrue);
      expect(FieldNetwork.isPrivateHost('my-mac.local'), isFalse);
      expect(FieldNetwork.isPrivateHost('1.1.1.1'), isFalse);
    });
  });

  group('user-addressed purposes', () {
    test('any https host the user typed is allowed', () async {
      final (client, seen) = recording();
      final net = FieldNetwork(inner: client);
      await net.get(
        Uri.parse('https://relay.test/v1/properties'),
        EgressPurpose.relayCustom,
      );
      await net.post(
        Uri.parse('https://llm.my-own-box.example/v1/chat/completions'),
        EgressPurpose.llmCustom,
      );
      expect(seen, hasLength(2));
    });

    test('plain http is still only for private addresses', () async {
      final (client, seen) = recording();
      final net = FieldNetwork(inner: client);
      await net.post(
        Uri.parse('http://192.168.1.5:11434/v1/chat/completions'),
        EgressPurpose.llmCustom,
      );
      expect(seen, hasLength(1));
      expect(
        () => net.get(
          Uri.parse('http://maps.example.com/area.pmtiles'),
          EgressPurpose.basemapLink,
        ),
        throwsA(isA<EgressBlocked>()),
      );
    });
  });

  group('the purpose log', () {
    test('names the host and purpose, never the path or query', () async {
      final (client, _) = recording();
      final net = FieldNetwork(inner: client);
      await net.get(
        Uri.parse(
          'https://archive-api.open-meteo.com/v1/archive'
          '?latitude=31.06&longitude=-98.19&start_date=2026-09-01',
        ),
        EgressPurpose.weather,
      );
      await net.post(
        Uri.parse(
          'https://my-api.plantnet.org/v2/identify/k-world-flora'
          '?api-key=SECRET-KEY-123',
        ),
        EgressPurpose.plantnet,
      );
      final lines = egressLines();
      expect(lines, [
        'egress archive-api.open-meteo.com weather',
        'egress my-api.plantnet.org plantnet',
      ]);
      final all = lines.join('\n');
      expect(all, isNot(contains('31.06')));
      expect(all, isNot(contains('-98.19')));
      expect(all, isNot(contains('SECRET')));
      expect(all, isNot(contains('/v1/')));
      expect(all, isNot(contains('?')));
    });

    test('a refused request is not logged as egress', () async {
      final net = FieldNetwork(inner: neverConnects());
      try {
        await net.get(
          Uri.parse('https://evil.example.com/'),
          EgressPurpose.weather,
        );
      } on EgressBlocked {
        // expected
      }
      expect(egressLines(), isEmpty);
    });

    test('repeats inside the window are counted, not written', () async {
      final (client, _) = recording();
      var now = DateTime(2026, 10, 13, 12);
      final net = FieldNetwork(inner: client, clock: () => now);
      final tile = Uri.parse(
        'https://imagery.nationalmap.gov/arcgis/rest/services/x/exportImage',
      );
      for (var i = 0; i < 50; i++) {
        await net.get(tile, EgressPurpose.imageryCapture);
      }
      expect(egressLines(), hasLength(1));
      now = now.add(const Duration(minutes: 2));
      await net.get(tile, EgressPurpose.imageryCapture);
      expect(egressLines(), [
        'egress imagery.nationalmap.gov imagery-capture',
        'egress imagery.nationalmap.gov imagery-capture (and 49 more)',
      ]);
    });
  });

  group('network policy (D-016)', () {
    test('a bulk purpose on blocked cellular is refused before connecting', () {
      final net = FieldNetwork(
        inner: neverConnects(),
        bulkVerdict: () async => BulkVerdict.cellularBlocked,
      );
      expect(
        () => net.get(
          Uri.parse('https://build.protomaps.com/20261013.pmtiles'),
          EgressPurpose.basemap,
        ),
        throwsA(isA<EgressBlocked>()),
      );
    });

    test('a small lookup is not held to the bulk policy', () async {
      final (client, seen) = recording();
      final net = FieldNetwork(
        inner: client,
        bulkVerdict: () async => BulkVerdict.cellularBlocked,
      );
      await net.get(
        Uri.parse('https://archive-api.open-meteo.com/v1/archive'),
        EgressPurpose.weather,
      );
      expect(seen, hasLength(1));
    });

    test('"use data this once" lets bulk through until it lapses', () async {
      final (client, seen) = recording();
      var now = DateTime(2026, 10, 13, 12);
      final net = FieldNetwork(
        inner: client,
        clock: () => now,
        bulkVerdict: () async => BulkVerdict.cellularBlocked,
      );
      final uri = Uri.parse('https://build.protomaps.com/20261013.pmtiles');
      net.allowCellularFor(const Duration(hours: 1));
      await net.get(uri, EgressPurpose.basemap);
      expect(seen, hasLength(1));
      now = now.add(const Duration(hours: 2));
      expect(
        () => net.get(uri, EgressPurpose.basemap),
        throwsA(isA<EgressBlocked>()),
      );
    });

    test('the verdict is cached briefly so a capture does not poll', () async {
      final (client, _) = recording();
      var asks = 0;
      var now = DateTime(2026, 10, 13, 12);
      final net = FieldNetwork(
        inner: client,
        clock: () => now,
        bulkVerdict: () async {
          asks++;
          return BulkVerdict.ok;
        },
      );
      final uri = Uri.parse('https://build.protomaps.com/20261013.pmtiles');
      for (var i = 0; i < 20; i++) {
        await net.get(uri, EgressPurpose.basemap);
      }
      expect(asks, 1);
      now = now.add(const Duration(seconds: 30));
      await net.get(uri, EgressPurpose.basemap);
      expect(asks, 2);
    });

    test('without a policy wired (tests, pre-prefs) nothing is held', () async {
      final (client, seen) = recording();
      final net = FieldNetwork(inner: client);
      expect(await net.bulkVerdict(), BulkVerdict.ok);
      await net.get(
        Uri.parse('https://build.protomaps.com/20261013.pmtiles'),
        EgressPurpose.basemap,
      );
      expect(seen, hasLength(1));
    });
  });

  group('forClient', () {
    test('null means the shared instance; a client is wrapped', () {
      FieldNetwork.resetForTesting();
      expect(FieldNetwork.forClient(null), same(FieldNetwork.instance));
      final wrapped = FieldNetwork.forClient(neverConnects());
      expect(wrapped, isNot(same(FieldNetwork.instance)));
    });
  });

  test('docs/EGRESS.md names every host on the allowlist', () {
    // The test runs from app/; the doc lives beside DECISIONS.md.
    final doc = File('../docs/EGRESS.md');
    expect(doc.existsSync(), isTrue, reason: 'docs/EGRESS.md is missing');
    final text = doc.readAsStringSync();
    for (final entry in kEgressAllowlist) {
      expect(
        text.contains(entry),
        isTrue,
        reason: '$entry is on kEgressAllowlist but not in docs/EGRESS.md',
      );
    }
    // And every purpose has a row, so a new one cannot go undocumented.
    for (final purpose in const [
      EgressPurpose.weather,
      EgressPurpose.soil,
      EgressPurpose.drive,
      EgressPurpose.driveAuth,
      EgressPurpose.relay,
      EgressPurpose.relayCustom,
      EgressPurpose.lan,
      EgressPurpose.local,
      EgressPurpose.plantnet,
      EgressPurpose.llm,
      EgressPurpose.llmCustom,
      EgressPurpose.inat,
      EgressPurpose.basemap,
      EgressPurpose.basemapLink,
      EgressPurpose.imageryCapture,
      EgressPurpose.satellite,
      EgressPurpose.plate,
      EgressPurpose.kmlLink,
    ]) {
      expect(
        text.contains('`${purpose.name}`'),
        isTrue,
        reason: 'purpose ${purpose.name} has no row in docs/EGRESS.md',
      );
    }
  });
}
