import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'lan_target.dart';

/// The desktop half of LAN backup: a small server that accepts an encrypted
/// blob store from the phone over the local network.
///
/// It is deliberately dumb. It authenticates a pairing code, writes bytes
/// into a folder, and lists what it has. It never decrypts anything — the
/// phone encrypts before sending, and the passphrase never leaves the phone.
///
/// Only bound while the user has the screen open and switched on.
class LanReceiver extends ChangeNotifier {
  LanReceiver({required this.storeDir});

  /// Where received files land — one folder per phone-side store path.
  final Directory storeDir;

  HttpServer? _server;
  String? _token;
  String? _address;
  int _received = 0;
  DateTime? _lastAt;
  String? error;

  bool get running => _server != null;
  String? get pairingCode => _token;
  String? get address => _address;
  int get port => _server?.port ?? LanTarget.defaultPort;
  int get filesReceived => _received;
  DateTime? get lastReceivedAt => _lastAt;

  /// Everything the phone needs, as a single string to type or scan.
  String? get pairingString => (_address == null || _token == null)
      ? null
      : LanTarget.encodePairing(_address!, port, _token!);

  Future<void> start() async {
    if (running) return;
    error = null;
    try {
      _token = _code();
      _address = await _lanAddress();
      _server = await shelf_io.serve(
        _handler,
        InternetAddress.anyIPv4,
        LanTarget.defaultPort,
        shared: true,
      );
      _received = 0;
      notifyListeners();
    } catch (e) {
      error = 'Could not start: $e';
      _server = null;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _token = null;
    notifyListeners();
  }

  /// Six digits, easy to read across a room and useless tomorrow.
  String _code() {
    final r = Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  /// The address a phone on the same network can actually reach.
  Future<String?> _lanAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<Response> _handler(Request req) async {
    final auth = req.headers['authorization'];
    if (_token == null || auth != 'Bearer $_token') {
      return Response.forbidden('pair first');
    }
    final segments = req.url.pathSegments;

    if (segments.isNotEmpty && segments.first == 'hello') {
      return Response.ok(
        jsonEncode({'app': 'field_notes', 'role': 'receiver'}),
        headers: {'content-type': 'application/json'},
      );
    }

    if (segments.isNotEmpty && segments.first == 'list') {
      final prefix = req.url.queryParameters['prefix'] ?? '';
      final dir = Directory(p.join(storeDir.path, prefix));
      if (!dir.existsSync()) {
        return Response.ok('[]', headers: {'content-type': 'application/json'});
      }
      final out = [
        for (final e in dir.listSync(recursive: true))
          if (e is File) p.relative(e.path, from: storeDir.path),
      ];
      return Response.ok(
        jsonEncode(out),
        headers: {'content-type': 'application/json'},
      );
    }

    if (segments.length < 2 || segments.first != 'backup') {
      return Response.notFound('no');
    }
    // Never let a path escape the store, whatever the phone sends.
    final rel = p.joinAll(segments.sublist(1));
    final target = File(p.normalize(p.join(storeDir.path, rel)));
    if (!p.isWithin(storeDir.path, target.path)) {
      return Response.forbidden('bad path');
    }

    switch (req.method) {
      case 'HEAD':
        return target.existsSync()
            ? Response.ok(null)
            : Response.notFound(null);
      case 'GET':
        if (!target.existsSync()) return Response.notFound('missing');
        return Response.ok(
          target.readAsBytesSync(),
          headers: {'content-type': 'application/octet-stream'},
        );
      case 'PUT':
        final bytes = await req.read().expand((c) => c).toList();
        target.parent.createSync(recursive: true);
        // Write-then-rename, so an interrupted push never leaves a torn file.
        final tmp = File('${target.path}.part')
          ..writeAsBytesSync(bytes, flush: true);
        tmp.renameSync(target.path);
        _received++;
        _lastAt = DateTime.now();
        notifyListeners();
        return Response.ok('ok');
      case 'DELETE':
        if (target.existsSync()) target.deleteSync();
        return Response.ok('ok');
      default:
        return Response(405);
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _server = null;
    super.dispose();
  }
}
