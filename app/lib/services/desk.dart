import 'dart:io';

/// One fact, one home (D-024): a "desk" is any computer build. Everything
/// that branches on phone-vs-desk reads this instead of re-deriving the
/// platform list — four copies of `Platform.isMacOS || …` had grown by the
/// time this file existed.
final bool isDesk = Platform.isMacOS || Platform.isLinux || Platform.isWindows;
