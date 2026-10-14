import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/field_network.dart';
import 'pmtiles_reader.dart' show HttpRangeSource;

/// Downloads and manages the offline basemap archive.
///
/// Any direct `.pmtiles` URL works (self-hosted, S3, a friend's server) —
/// the user typed it, so it goes out as [EgressPurpose.basemapLink].
/// Downloads resume via HTTP Range if interrupted — rural LTE drops matter.
class BasemapManager extends ChangeNotifier {
  BasemapManager({FieldNetwork? network}) : _given = network;

  final FieldNetwork? _given;
  FieldNetwork get _net => _given ?? FieldNetwork.instance;

  static const fileName = 'basemap.pmtiles';

  double? progress; // 0..1 while downloading, null when idle
  String? error;
  bool get downloading => progress != null;

  Future<File> _target() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'basemap'))
      ..createSync(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  Future<bool> isInstalled() async => (await _target()).existsSync();

  Future<int?> installedBytes() async {
    final f = await _target();
    return f.existsSync() ? f.lengthSync() : null;
  }

  Future<void> remove() async {
    final f = await _target();
    if (f.existsSync()) f.deleteSync();
    notifyListeners();
  }

  /// Downloads [url] to the basemap slot. Resumes a partial `.part` file.
  Future<void> download(String url) async {
    if (downloading) return;
    error = null;
    progress = 0;
    notifyListeners();

    try {
      final target = await _target();
      final part = File('${target.path}.part');
      final existing = part.existsSync() ? part.lengthSync() : 0;

      final req = http.Request('GET', Uri.parse(url));
      if (existing > 0) {
        req.headers[HttpHeaders.rangeHeader] = 'bytes=$existing-';
      }
      final res = await _net.send(req, HttpRangeSource.purposeFor(url));
      if (res.statusCode != 200 && res.statusCode != 206) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final resuming = res.statusCode == 206;
      final length = res.contentLength ?? 0;
      final total = (resuming ? existing : 0) + (length > 0 ? length : 0);
      var received = resuming ? existing : 0;

      final sink = part.openSync(
        mode: resuming ? FileMode.writeOnlyAppend : FileMode.writeOnly,
      );
      try {
        await for (final chunk in res.stream) {
          sink.writeFromSync(chunk);
          received += chunk.length;
          if (total > 0) {
            progress = received / total;
            notifyListeners();
          }
        }
      } finally {
        sink.closeSync();
      }
      if (target.existsSync()) target.deleteSync();
      part.renameSync(target.path);
    } catch (e) {
      error = '$e';
    } finally {
      progress = null;
      notifyListeners();
    }
  }
}
