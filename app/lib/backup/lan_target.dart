import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'target.dart';

/// Back up to a computer on your own network (spec §11.5, "local folder"
/// taken literally: the folder is on your desk, not in a data centre).
///
/// The desktop app runs a receiver; the phone pushes to it over the LAN.
/// Nothing touches the internet, no account exists, and the payload is the
/// same encrypted blob store as every other target — the receiver only ever
/// sees opaque files with meaningless names.
///
/// Pairing is a six-digit code shown on the desktop. It becomes a bearer
/// token for every request, so another device on the same café Wi-Fi can't
/// read or overwrite the store by guessing the port.
class LanTarget implements BackupTarget {
  LanTarget({
    required this.host,
    required this.port,
    required this.token,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String host;
  final int port;
  final String token;
  final http.Client _client;

  static const defaultPort = 51703;

  /// How the pairing details travel between the two screens.
  static String encodePairing(String host, int port, String token) =>
      'fieldnotes://backup?host=$host&port=$port&code=$token';

  static ({String host, int port, String token})? decodePairing(String raw) {
    try {
      final uri = Uri.parse(raw.trim());
      final host = uri.queryParameters['host'];
      final port = int.tryParse(uri.queryParameters['port'] ?? '');
      final code = uri.queryParameters['code'];
      if (host == null || port == null || code == null) return null;
      return (host: host, port: port, token: code);
    } catch (_) {
      return null;
    }
  }

  Uri _uri(String path) =>
      Uri.http('$host:$port', '/backup/$path');

  Map<String, String> get _headers => {'authorization': 'Bearer $token'};

  @override
  String get description => '$host:$port';

  /// Is the receiver up and does it accept our code?
  Future<bool> ping() async {
    try {
      final res = await _client
          .get(Uri.http('$host:$port', '/hello'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> exists(String path) async {
    try {
      final res = await _client
          .head(_uri(path), headers: _headers)
          .timeout(const Duration(seconds: 15));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Uint8List> read(String path) async {
    final res = await _client
        .get(_uri(path), headers: _headers)
        .timeout(const Duration(minutes: 2));
    if (res.statusCode != 200) {
      throw LanTargetException('Could not read $path (${res.statusCode})');
    }
    return res.bodyBytes;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final res = await _client
        .put(_uri(path),
            headers: {..._headers, 'content-type': 'application/octet-stream'},
            body: bytes)
        .timeout(const Duration(minutes: 5));
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw LanTargetException(
          'The computer refused that file (${res.statusCode})');
    }
  }

  @override
  Future<List<String>> list(String prefix) async {
    final res = await _client
        .get(Uri.http('$host:$port', '/list', {'prefix': prefix}),
            headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) return const [];
    final data = jsonDecode(res.body);
    if (data is! List) return const [];
    return [for (final e in data) '$e'];
  }

  @override
  Future<void> delete(String path) async {
    try {
      await _client
          .delete(_uri(path), headers: _headers)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      // An old generation left behind costs disk, not safety.
    }
  }

  void close() => _client.close();
}

class LanTargetException implements Exception {
  LanTargetException(this.message);
  final String message;
  @override
  String toString() => message;
}
