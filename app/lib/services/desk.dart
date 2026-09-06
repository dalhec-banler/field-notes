import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// One fact, one home (D-024): a "desk" is any computer build. Everything
/// that branches on phone-vs-desk reads this instead of re-deriving the
/// platform list — four copies of `Platform.isMacOS || …` had grown by the
/// time this file existed.
final bool isDesk = Platform.isMacOS || Platform.isLinux || Platform.isWindows;

/// Hands a file (a zip, a PDF) to the person. A desk saves it where they
/// point — a mobile share sheet on a computer was posture untruth (design
/// audit P2-9); a phone opens the share sheet. Returns where they now have
/// it (the chosen path on a desk, the file itself after a share), or null
/// if they cancelled the save.
Future<String?> deliverFile(String path, {required String text}) async {
  if (isDesk) {
    final ext = p.extension(path).replaceFirst('.', '');
    final loc = await getSaveLocation(
      suggestedName: p.basename(path),
      acceptedTypeGroups: [
        XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    if (loc == null) return null;
    await File(path).copy(loc.path);
    return loc.path;
  }
  await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: text));
  return path;
}
