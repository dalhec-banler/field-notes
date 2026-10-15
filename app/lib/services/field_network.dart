import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'diag.dart';
import 'network_policy.dart';

/// The one door out of the phone (D-038 item 4).
///
/// Every HTTP request the app makes goes through an instance of this class.
/// Before a socket is opened, [check] decides whether the request may leave
/// at all:
///
///  * the host must be on [kEgressAllowlist] (exact host, or `*.suffix`),
///    unless the purpose says otherwise:
///  * [EgressScope.local] purposes may only talk to this device
///    (127.0.0.0/8, ::1), which is the loopback tile server;
///  * [EgressScope.lan] purposes may talk to loopback and private addresses
///    (RFC 1918, link-local, CGNAT, ULA) — the computer on your own network;
///  * [EgressScope.userAddressed] purposes carry an address the user typed
///    themselves — a custom relay, an OpenAI-compatible endpoint on their
///    own box, a `.pmtiles` link, a map share link. The user chose the
///    destination, so the allowlist does not apply; plaintext `http://` is
///    still refused unless the host is private or loopback.
///
/// A refused request throws [EgressBlocked] and nothing is connected.
///
/// Bulk purposes (basemap and imagery capture, backup uploads) are also held
/// to the network policy (D-016): on cellular without the user's switch the
/// request is refused here rather than at whichever screen remembered to
/// ask. A one-off "use data this once" grant is [allowCellularFor].
///
/// Every request is noted in [Diag] as `egress <host> <purpose>` — host and
/// purpose only, never the path or query, because the query is where
/// coordinates, keys and tokens ride. Repeats of the same host and purpose
/// within a minute are counted rather than written (a capture is thousands
/// of tile requests), so the Diagnostics ring stays readable.
class FieldNetwork {
  FieldNetwork({
    http.Client? inner,
    Future<BulkVerdict> Function()? bulkVerdict,
    DateTime Function()? clock,
    this.shared = false,
  }) : _inner = inner ?? http.Client(),
       _policy = bulkVerdict,
       _clock = clock ?? _wallClock;

  /// True for the app's own network. A shared network ignores [close]: it
  /// has to outlive every target built on it.
  final bool shared;

  static DateTime _wallClock() => DateTime.now();

  /// The app's client. Screens and services that are not handed one use
  /// this; [install] gives it the network policy once prefs are loaded.
  static FieldNetwork instance = FieldNetwork(shared: true);

  /// The constructor seam every service keeps for its tests: a mocked
  /// `http.Client` is wrapped, so the allowlist still applies to it; null
  /// means the app's own [instance].
  static FieldNetwork forClient(http.Client? client) =>
      client == null ? instance : FieldNetwork(inner: client);

  /// Wire the D-016 policy into the app instance. Called once from `main`
  /// after prefs load; before that no request is a bulk one.
  static void install({required Future<BulkVerdict> Function() bulkVerdict}) {
    instance = FieldNetwork(
      inner: instance._inner,
      bulkVerdict: bulkVerdict,
      clock: instance._clock,
      shared: true,
    );
  }

  final http.Client _inner;
  final Future<BulkVerdict> Function()? _policy;
  final DateTime Function() _clock;

  /// How long a bulk verdict is reused before the connectivity plugin is
  /// asked again. A capture asks thousands of times a minute.
  static const verdictTtl = Duration(seconds: 10);

  /// How long repeats of one `host purpose` are counted instead of logged.
  static const logWindow = Duration(seconds: 60);

  BulkVerdict? _verdict;
  DateTime? _verdictAt;
  DateTime? _cellularUntil;

  final Map<String, DateTime> _lastLogged = {};
  final Map<String, int> _sinceLogged = {};

  /// The user said "use data this once": bulk purposes may run on cellular
  /// until [until] passes, whatever the switch says.
  void allowCellularFor(Duration d) => _cellularUntil = _clock().add(d);

  /// D-016's verdict for a bulk transfer right now — the screens ask this
  /// before they start, so they can say "waiting for Wi-Fi" in words rather
  /// than fail mid-download.
  Future<BulkVerdict> bulkVerdict() async {
    final f = _policy;
    if (f == null) return BulkVerdict.ok;
    final now = _clock();
    final at = _verdictAt;
    if (_verdict != null && at != null && now.difference(at) < verdictTtl) {
      return _verdict!;
    }
    final v = await f();
    _verdict = v;
    _verdictAt = now;
    return v;
  }

  // ── the surface ────────────────────────────────────────────────────

  Future<http.Response> get(
    Uri uri,
    EgressPurpose purpose, {
    Map<String, String>? headers,
  }) async {
    await check(uri, purpose);
    return _inner.get(uri, headers: headers);
  }

  Future<http.Response> head(
    Uri uri,
    EgressPurpose purpose, {
    Map<String, String>? headers,
  }) async {
    await check(uri, purpose);
    return _inner.head(uri, headers: headers);
  }

  Future<http.Response> post(
    Uri uri,
    EgressPurpose purpose, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    await check(uri, purpose);
    return _inner.post(uri, headers: headers, body: body);
  }

  Future<http.Response> put(
    Uri uri,
    EgressPurpose purpose, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    await check(uri, purpose);
    return _inner.put(uri, headers: headers, body: body);
  }

  Future<http.Response> delete(
    Uri uri,
    EgressPurpose purpose, {
    Map<String, String>? headers,
  }) async {
    await check(uri, purpose);
    return _inner.delete(uri, headers: headers);
  }

  /// Streamed: multipart uploads, range reads, downloads written to disk.
  Future<http.StreamedResponse> send(
    http.BaseRequest request,
    EgressPurpose purpose,
  ) async {
    await check(request.url, purpose);
    return _inner.send(request);
  }

  /// Done with a network of one's own. The app's [instance] ignores this.
  ///
  /// Every target takes `http.Client? client` for its tests and passes it to
  /// [forClient], which answers with [instance] when the client is null — so
  /// `DriveTarget.close()` in a `finally` was closing the client the whole
  /// app shares, and every request after the session's first Drive call
  /// threw "Client is already closed" (a Drive backup, 2026-10-15). A target
  /// closes the client it was given, never the one it borrowed.
  void close() {
    if (shared) return;
    _inner.close();
  }

  // ── the gate ───────────────────────────────────────────────────────

  /// Decides, logs, and throws [EgressBlocked] when the request may not
  /// leave. Public so a caller can refuse early (before building a large
  /// body); every method above calls it.
  Future<void> check(Uri uri, EgressPurpose purpose) async {
    final host = uri.host.toLowerCase();
    if (host.isEmpty) {
      throw EgressBlocked(host, purpose, 'no host');
    }
    final private = isPrivateHost(host);
    final loopback = isLoopbackHost(host);
    final allowed = switch (purpose.scope) {
      EgressScope.local => loopback,
      EgressScope.lan => loopback || private,
      EgressScope.userAddressed => true,
      EgressScope.allowlist => hostAllowed(host),
    };
    if (!allowed) {
      throw EgressBlocked(host, purpose, 'host is not on the allowlist');
    }
    if (uri.scheme != 'https' && !(loopback || private)) {
      throw EgressBlocked(host, purpose, 'plaintext http to a public host');
    }
    if (purpose.bulk && _policy != null) {
      final until = _cellularUntil;
      final granted = until != null && _clock().isBefore(until);
      if (!granted && await bulkVerdict() == BulkVerdict.cellularBlocked) {
        throw EgressBlocked(
          host,
          purpose,
          'on cellular — allow it in Settings → Network',
        );
      }
    }
    _note(host, purpose);
  }

  void _note(String host, EgressPurpose purpose) {
    final key = '$host ${purpose.name}';
    final now = _clock();
    final last = _lastLogged[key];
    if (last != null && now.difference(last) < logWindow) {
      _sinceLogged[key] = (_sinceLogged[key] ?? 0) + 1;
      return;
    }
    final repeats = _sinceLogged.remove(key) ?? 0;
    _lastLogged[key] = now;
    Diag.log(
      repeats == 0 ? 'egress $key' : 'egress $key (and $repeats more)',
      where: 'FieldNetwork',
    );
  }

  /// True when [host] matches an entry of [kEgressAllowlist].
  static bool hostAllowed(String host) {
    final h = host.toLowerCase();
    for (final entry in kEgressAllowlist) {
      if (entry.startsWith('*.')) {
        final suffix = entry.substring(1); // ".googleapis.com"
        if (h.endsWith(suffix) && h.length > suffix.length) return true;
      } else if (h == entry) {
        return true;
      }
    }
    return false;
  }

  /// 127.0.0.0/8, ::1, `localhost`.
  static bool isLoopbackHost(String host) {
    if (host == 'localhost') return true;
    final a = InternetAddress.tryParse(_stripBrackets(host));
    return a?.isLoopback ?? false;
  }

  /// An address that cannot be routed on the public internet: RFC 1918,
  /// link-local, CGNAT (100.64/10 — Tailscale and the like), IPv6 ULA and
  /// link-local. Names (`my-mac.local`) are not addresses and are not
  /// private by this test.
  static bool isPrivateHost(String host) {
    final a = InternetAddress.tryParse(_stripBrackets(host));
    if (a == null) return false;
    if (a.isLoopback || a.isLinkLocal) return true;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) {
      if (b[0] == 10) return true;
      if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
      if (b[0] == 192 && b[1] == 168) return true;
      if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
      return false;
    }
    // fc00::/7
    return (b[0] & 0xfe) == 0xfc;
  }

  static String _stripBrackets(String host) =>
      host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;

  @visibleForTesting
  static void resetForTesting() => instance = FieldNetwork();
}

/// Where a purpose may go. See [FieldNetwork].
enum EgressScope { allowlist, local, lan, userAddressed }

/// Why a request is being made, in one word that lands in the Diagnostics
/// log next to the host. One per thing the app talks to; `docs/EGRESS.md`
/// is the long form.
class EgressPurpose {
  const EgressPurpose._(
    this.name, {
    this.scope = EgressScope.allowlist,
    this.bulk = false,
  });

  final String name;
  final EgressScope scope;

  /// Held to the D-016 policy (Wi-Fi unless cellular is allowed).
  final bool bulk;

  /// Open-Meteo daily archive for a record's coarsened point (D-022).
  static const weather = EgressPurpose._('weather');

  /// NRCS Soil Data Access: the map unit under a coarsened point (D-022).
  static const soil = EgressPurpose._('soil');

  /// Google Drive app folder: sealed blobs up and down (D-021). Not marked
  /// bulk here: the same target carries a few rows of sync and a hundred
  /// photos, and only the engine knows which — `BackupService` and
  /// `SyncService` ask [FieldNetwork.bulkVerdict] before media moves.
  static const drive = EgressPurpose._('drive');

  /// Google OAuth token exchange, refresh and revoke on the desk (D-024).
  static const driveAuth = EgressPurpose._('drive-auth');

  /// The Field Notes relay at its default address (D-031). Policy as for
  /// [drive].
  static const relay = EgressPurpose._('relay');

  /// A relay the user pointed the app at instead.
  static const relayCustom = EgressPurpose._(
    'relay-custom',
    scope: EgressScope.userAddressed,
  );

  /// The paired computer on the local network (D-019).
  static const lan = EgressPurpose._('lan', scope: EgressScope.lan);

  /// This device's own loopback tile server.
  static const local = EgressPurpose._('local', scope: EgressScope.local);

  /// Pl@ntNet identification and key probe, with the user's own key (D-020).
  static const plantnet = EgressPurpose._('plantnet');

  /// Anthropic or OpenAI with the user's own key, at the provider's address.
  static const llm = EgressPurpose._('llm');

  /// An OpenAI-compatible endpoint the user typed in (their own server).
  static const llmCustom = EgressPurpose._(
    'llm-custom',
    scope: EgressScope.userAddressed,
  );

  /// iNaturalist: a state's species list, or counts near a coarse point.
  static const inat = EgressPurpose._('inat');

  /// Protomaps planet build: the vector basemap for a framed area.
  static const basemap = EgressPurpose._('basemap', bulk: true);

  /// A `.pmtiles` archive at a link the user pasted.
  static const basemapLink = EgressPurpose._(
    'basemap-link',
    scope: EgressScope.userAddressed,
    bulk: true,
  );

  /// NAIP imagery from USGS for offline capture (public domain).
  static const imageryCapture = EgressPurpose._('imagery-capture', bulk: true);

  /// Live satellite tiles proxied to the map through the loopback server.
  static const satellite = EgressPurpose._('satellite');

  /// Tiles and overlays for an export plate: USGS bases, NHD, contours,
  /// NRCS soils WMS.
  static const plate = EgressPurpose._('plate');

  /// A KML/KMZ map at a share link the user pasted (D-036).
  static const kmlLink = EgressPurpose._(
    'kml-link',
    scope: EgressScope.userAddressed,
  );

  @override
  String toString() => name;
}

/// A request that was not allowed to leave. Nothing was connected.
class EgressBlocked implements Exception {
  const EgressBlocked(this.host, this.purpose, this.reason);
  final String host;
  final EgressPurpose purpose;
  final String reason;

  @override
  String toString() => 'Not sent to $host ($purpose): $reason.';
}

/// Every host the app will open a connection to on its own. An entry is an
/// exact host or `*.suffix`. Each one is described in `docs/EGRESS.md`, and
/// a test keeps the two in step. Adding a host here is a decision, not a
/// fix: say what leaves and which setting gates it.
const kEgressAllowlist = <String>[
  // Environmental context (D-022)
  'archive-api.open-meteo.com',
  'sdmdataaccess.sc.egov.usda.gov',
  // Google Drive backup and sign-in (D-021, D-024)
  '*.googleapis.com',
  // The relay (D-031)
  'relay.fieldnotes.app',
  // Species identification (D-020)
  'my-api.plantnet.org',
  'api.anthropic.com',
  'api.openai.com',
  'api.inaturalist.org',
  // Maps and plates
  'build.protomaps.com',
  'basemap.nationalmap.gov',
  'imagery.nationalmap.gov',
  'hydro.nationalmap.gov',
  'carto.nationalmap.gov',
  'server.arcgisonline.com',
];
