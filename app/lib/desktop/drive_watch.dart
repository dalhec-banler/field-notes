import 'dart:convert';

import 'package:path_provider/path_provider.dart';

import '../backup/backup_engine.dart';
import '../backup/drive_auth.dart';
import '../backup/drive_target.dart';
import '../backup/restore.dart';
import '../services/app_prefs.dart';

/// A newer copy from the phone, waiting in Drive.
class DriveNews {
  const DriveNews({required this.generation, required this.createdAt});
  final int generation;
  final String createdAt;
}

/// The desk's one-way mirror until sync arrives (D-024/D-025): if Drive is
/// connected, read the manifest envelope — plaintext, tiny, no key needed
/// — and compare its generation with the one this copy was restored from.
/// Never interactive: a missing or expired grant means "no news", not a
/// browser window.
Future<DriveNews?> checkDriveForNewer(AppPrefs prefs) async {
  if (prefs.driveEmail == null) return null;
  DriveTarget? target;
  try {
    final token = await DriveAuth.instance.accessToken(interactive: false);
    if (token == null) return null;
    target = DriveTarget(accessToken: token);
    final path = '${BackupEngine.root}/manifest.json';
    if (!await target.exists(path)) return null;
    final envelope = jsonDecode(
      utf8.decode(await target.read(path)),
    ) as Map<String, dynamic>;
    final generation = (envelope['generation'] as num?)?.toInt() ?? 0;
    final createdAt = envelope['created_at'] as String? ?? '';
    final docs = await getApplicationDocumentsDirectory();
    final from = RestorePipeline(docs).lastRestoredFrom;
    final have = (from?['generation'] as num?)?.toInt() ?? 0;
    if (generation <= have) return null;
    return DriveNews(generation: generation, createdAt: createdAt);
  } catch (_) {
    return null;
  } finally {
    target?.close();
  }
}
