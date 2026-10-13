import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One thing that went wrong, or one thing worth noting, as the app saw it.
class DiagEntry {
  const DiagEntry({
    required this.at,
    required this.where,
    required this.message,
    this.frames,
  });

  /// UTC.
  final DateTime at;

  /// `Class.method` or `file.function` — the place that caught it.
  final String? where;
  final String message;

  /// The first few stack frames, already trimmed; null for a plain log line.
  final String? frames;

  /// The entry as one block of text, the way it is written to the file and
  /// copied to the clipboard.
  String format() {
    final b = StringBuffer()
      ..write(at.toIso8601String())
      ..write('  ')
      ..write(where ?? '-')
      ..write('  ')
      ..write(message);
    if (frames != null && frames!.isNotEmpty) {
      for (final line in frames!.split('\n')) {
        b
          ..write('\n    ')
          ..write(line);
      }
    }
    return b.toString();
  }
}

/// The diagnostics sink. Everything the app used to swallow lands here:
/// the last [ringCap] entries in memory for the Diagnostics screen, and the
/// same lines appended to `diag.log` under the app's support directory,
/// rotated once at about a megabyte.
///
/// Nothing leaves the device through this class, and nothing here may
/// throw — a diagnostics sink that takes the app down is worse than none.
abstract final class Diag {
  static const ringCap = 500;
  static const fileName = 'diag.log';

  /// Bytes before `diag.log` rolls over to `diag.log.1`. Not const so a
  /// test can roll it in a handful of lines.
  static int fileCap = 1 << 20;

  /// How many stack frames an entry keeps.
  static const frameCount = 6;

  static final ListQueue<DiagEntry> _ring = ListQueue();

  /// Pending file writes, chained so appends never interleave.
  static Future<void> _tail = Future.value();

  static Future<Directory?>? _dir;

  /// Where the log lives. Set from tests to point at a scratch (or an
  /// unwritable) place; left null, it is the app support directory.
  static Directory? directoryOverride;

  /// The ring, newest first.
  static List<DiagEntry> get entries => _ring.toList().reversed.toList();

  static int get length => _ring.length;

  /// Something went wrong and was handled. Keeps the fallback the caller
  /// already had; this only remembers that it happened.
  ///
  /// [st] is positional so a catch reads `Diag.report(e, st, where: …)`;
  /// pass null when there is no trace. (Dart will not take an optional
  /// positional next to named parameters.)
  static void report(
    Object error,
    StackTrace? st, {
    String? where,
    Map<String, Object?>? extra,
  }) {
    try {
      var message = _describe(error);
      if (extra != null && extra.isNotEmpty) {
        final parts = extra.entries.map((e) => '${e.key}=${e.value}');
        message = '$message  {${parts.join(', ')}}';
      }
      _add(
        DiagEntry(
          at: DateTime.now().toUtc(),
          where: where,
          message: message,
          frames: _trim(st),
        ),
      );
    } catch (_) {
      // The sink itself never throws.
    }
  }

  /// A plain note — a milestone, a decision, something a future reader of
  /// the log would want to see next to the errors.
  static void log(String message, {String? where}) {
    try {
      _add(
        DiagEntry(at: DateTime.now().toUtc(), where: where, message: message),
      );
    } catch (_) {
      // The sink itself never throws.
    }
  }

  /// Everything in the ring as text, newest first.
  static String dump() {
    final b = StringBuffer();
    for (final e in entries) {
      b
        ..writeln(e.format())
        ..writeln();
    }
    return b.toString();
  }

  /// Forgets the ring and empties the file. The `.1` rotation is kept.
  static Future<void> clear() async {
    _ring.clear();
    _tail = _tail.then((_) async {
      try {
        final f = await _file();
        if (f != null && f.existsSync()) await f.writeAsString('');
      } catch (_) {
        // Nothing to clear, or nowhere to clear it.
      }
    });
    await flush();
  }

  /// Resolves when every write queued so far has landed (or failed).
  static Future<void> flush() => _tail;

  /// Drops cached state so tests start clean. Does not touch files.
  @visibleForTesting
  static void resetForTesting() {
    _ring.clear();
    _dir = null;
    _tail = Future.value();
  }

  /// Installs the sink behind the framework's error hooks. Whatever was
  /// there before still runs, after this has taken its note — nothing is
  /// replaced, and the previous handler's verdict is the one that counts.
  static void install() {
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      report(
        details.exception,
        details.stack,
        where: 'FlutterError',
        extra: {
          if (details.library != null) 'library': details.library,
          if (details.context != null)
            'context': details.context!.toDescription(),
        },
      );
      prevFlutter?.call(details);
    };
    final prevPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack, where: 'PlatformDispatcher');
      if (prevPlatform != null) return prevPlatform(error, stack);
      return false;
    };
  }

  // ---- internals ----------------------------------------------------------

  static void _add(DiagEntry entry) {
    _ring.addLast(entry);
    while (_ring.length > ringCap) {
      _ring.removeFirst();
    }
    final line = '${entry.format()}\n';
    _tail = _tail.then((_) => _append(line)).catchError((_) {});
  }

  static String _describe(Object error) {
    try {
      final s = error.toString();
      return s.isEmpty ? error.runtimeType.toString() : s;
    } catch (_) {
      return error.runtimeType.toString();
    }
  }

  static String? _trim(StackTrace? st) {
    if (st == null) return null;
    try {
      final lines = st
          .toString()
          .split('\n')
          .map((l) => l.trimRight())
          .where((l) => l.isNotEmpty)
          .take(frameCount);
      final s = lines.join('\n');
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  static Future<File?> _file() async {
    final dir = await (_dir ??= _resolveDir());
    if (dir == null) return null;
    return File(p.join(dir.path, fileName));
  }

  static Future<Directory?> _resolveDir() async {
    try {
      final dir = directoryOverride ?? await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      // No support directory (host tests without a path provider, a
      // locked-down filesystem): the ring still works, the file does not.
      return null;
    }
  }

  static Future<void> _append(String line) async {
    try {
      final f = await _file();
      if (f == null) return;
      final bytes = line.length;
      if (f.existsSync() && f.lengthSync() + bytes > fileCap) {
        final old = File('${f.path}.1');
        if (old.existsSync()) await old.delete();
        await f.rename(old.path);
      }
      await f.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // An unwritable log is not a reason to stop; the ring still has it.
      // One failure does not keep the next line from trying again.
    }
  }
}
