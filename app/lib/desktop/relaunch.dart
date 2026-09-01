import 'dart:io';

/// Whether this platform can bring itself back after a quit. Only macOS
/// has a reliable "open the bundle" verb; elsewhere the user reopens.
bool get canRelaunch => Platform.isMacOS;

/// Quit and reopen (macOS), or just quit. Used after a restore is staged:
/// the staged copy applies before the database opens on the next launch
/// (spec §11.9), so the honest way to "finish" is a real process restart.
Future<void> relaunchApp() async {
  if (Platform.isMacOS) {
    // …/field_notes.app/Contents/MacOS/field_notes → the bundle.
    final bundle = File(Platform.resolvedExecutable).parent.parent.parent.path;
    await Process.start('/bin/sh', [
      '-c',
      'sleep 1; /usr/bin/open "\$0"',
      bundle,
    ], mode: ProcessStartMode.detached);
  }
  exit(0);
}
