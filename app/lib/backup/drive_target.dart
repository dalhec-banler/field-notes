import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'target.dart';

/// Back up to the user's own Google Drive (D-020).
///
/// The scope is `drive.appdata` and nothing else: a hidden folder that Drive
/// creates for this app, which no other app — and no human browsing Drive —
/// can see or open. We cannot read the user's documents, photos, or anything
/// that was already there. That limitation is the point, not a compromise.
///
/// What lands there is the same encrypted blob store as every other target.
/// The phone seals every object before it leaves; Google stores ciphertext
/// with meaningless names and holds no key.
///
/// ## Why an index
///
/// Drive has no paths. Every object is a file with a `name` and an opaque id,
/// and finding one by name costs a query. [BackupEngine.backup] calls
/// [exists] once per blob, so a query per call would make a first backup of a
/// few hundred photos take minutes. Instead we page the whole appDataFolder
/// listing once ([_ensureIndex]) and keep a name → id map for the life of the
/// target. Writes update the map, so the index never goes stale mid-run.
///
/// Slashes are legal in Drive names but confuse the console and the API's
/// query escaping, so `fieldnotes/blobs/ab/cd` is stored as
/// `fieldnotes__blobs__ab__cd`. [_encode]/[_decode] are the only places that
/// know this.
class DriveTarget implements BackupTarget {
  DriveTarget({required this.accessToken, http.Client? client})
    : _client = client ?? http.Client();

  /// A short-lived OAuth access token for scope `drive.appdata`.
  final String accessToken;
  final http.Client _client;

  static const scope = 'https://www.googleapis.com/auth/drive.appdata';
  static const _api = 'www.googleapis.com';
  static const _space = 'appDataFolder';

  /// name → file id, built once per target instance.
  Map<String, String>? _index;

  @override
  String get description => 'Google Drive (app folder)';

  Map<String, String> get _auth => {'authorization': 'Bearer $accessToken'};

  static String _encode(String path) => path.replaceAll('/', '__');
  static String _decode(String name) => name.replaceAll('__', '/');

  /// Page the whole app folder. Files are few (one DB dump per generation
  /// plus one per photo) and the listing is cheap next to the transfers.
  Future<Map<String, String>> _ensureIndex() async {
    final cached = _index;
    if (cached != null) return cached;
    final index = <String, String>{};
    String? pageToken;
    do {
      final uri = Uri.https(_api, '/drive/v3/files', {
        'spaces': _space,
        'fields': 'nextPageToken,files(id,name)',
        'pageSize': '1000',
        if (pageToken != null) 'pageToken': pageToken,
      });
      final res = await _client
          .get(uri, headers: _auth)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw DriveException(_explain(res.statusCode, res.body));
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      for (final f in (body['files'] as List? ?? const [])) {
        final m = f as Map<String, dynamic>;
        index[m['name'] as String] = m['id'] as String;
      }
      pageToken = body['nextPageToken'] as String?;
    } while (pageToken != null);
    _index = index;
    return index;
  }

  @override
  Future<bool> exists(String path) async =>
      (await _ensureIndex()).containsKey(_encode(path));

  @override
  Future<Uint8List> read(String path) async {
    final id = (await _ensureIndex())[_encode(path)];
    if (id == null) throw DriveException('Not in Drive: $path');
    final res = await _client
        .get(
          Uri.https(_api, '/drive/v3/files/$id', {'alt': 'media'}),
          headers: _auth,
        )
        .timeout(const Duration(minutes: 2));
    if (res.statusCode != 200) {
      throw DriveException(_explain(res.statusCode, res.body));
    }
    return res.bodyBytes;
  }

  /// Drive has no rename-into-place, so an interrupted upload leaves nothing
  /// rather than a half file: the file only appears once the request
  /// completes. Re-writing an existing name PATCHes that file's content in
  /// place, which keeps the id — and the index — stable.
  @override
  Future<void> write(String path, Uint8List bytes) async {
    final name = _encode(path);
    final index = await _ensureIndex();
    final existing = index[name];

    final boundary = 'fieldnotes-${DateTime.now().microsecondsSinceEpoch}';
    final metadata = existing == null
        ? {
            'name': name,
            'parents': [_space],
          }
        : {'name': name};
    final head = utf8.encode(
      '--$boundary\r\n'
      'Content-Type: application/json; charset=UTF-8\r\n\r\n'
      '${jsonEncode(metadata)}\r\n'
      '--$boundary\r\n'
      'Content-Type: application/octet-stream\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final body = Uint8List(head.length + bytes.length + tail.length)
      ..setRange(0, head.length, head)
      ..setRange(head.length, head.length + bytes.length, bytes)
      ..setRange(
        head.length + bytes.length,
        head.length + bytes.length + tail.length,
        tail,
      );

    final uri = Uri.https(
      _api,
      existing == null
          ? '/upload/drive/v3/files'
          : '/upload/drive/v3/files/$existing',
      const {'uploadType': 'multipart', 'fields': 'id'},
    );
    final request = http.Request(existing == null ? 'POST' : 'PATCH', uri)
      ..headers.addAll({
        ..._auth,
        'content-type': 'multipart/related; boundary=$boundary',
      })
      ..bodyBytes = body;

    final streamed = await _client
        .send(request)
        .timeout(const Duration(minutes: 5));
    final text = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw DriveException(_explain(streamed.statusCode, text));
    }
    final id = (jsonDecode(text) as Map<String, dynamic>)['id'] as String?;
    if (id != null) index[name] = id;
    // (an id is always returned for a successful upload; the guard is only
    // so a surprising response cannot poison the index with a null)
  }

  @override
  Future<List<String>> list(String prefix) async {
    final want = _encode(prefix.endsWith('/') ? prefix : '$prefix/');
    return [
      for (final name in (await _ensureIndex()).keys)
        if (name.startsWith(want)) _decode(name),
    ];
  }

  @override
  Future<void> delete(String path) async {
    final name = _encode(path);
    final index = await _ensureIndex();
    final id = index[name];
    if (id == null) return;
    final res = await _client
        .delete(Uri.https(_api, '/drive/v3/files/$id'), headers: _auth)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode == 200 ||
        res.statusCode == 204 ||
        res.statusCode == 404) {
      index.remove(name);
      return;
    }
    throw DriveException(_explain(res.statusCode, res.body));
  }

  void close() => _client.close();

  /// Google's errors are JSON blobs aimed at developers. Say the useful part
  /// in words a person can act on.
  static String _explain(int status, String body) {
    if (status == 401) {
      return 'Google sign-in expired. Open Backup and connect again.';
    }
    if (status == 403 && body.contains('storageQuotaExceeded')) {
      return 'This Google account is out of Drive storage.';
    }
    if (status == 403) {
      return 'Google refused the request. Check the app still has permission '
          'at myaccount.google.com/permissions.';
    }
    if (status == 429 || status == 503) {
      return 'Google is rate-limiting this account. Try again shortly.';
    }
    String detail = '';
    try {
      final m = jsonDecode(body) as Map<String, dynamic>;
      detail = ((m['error'] as Map?)?['message'] as String?) ?? '';
    } catch (_) {}
    return 'Google Drive error $status${detail.isEmpty ? '' : ': $detail'}';
  }
}

class DriveException implements Exception {
  const DriveException(this.message);
  final String message;
  @override
  String toString() => message;
}
