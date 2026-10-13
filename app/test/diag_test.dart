import 'dart:io';

import 'package:field_notes/services/diag.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The diagnostics sink: a ring in memory, a rotating file on disk, and a
/// hook behind the framework's own error handlers. The one property that
/// matters more than any other is that it never throws — a sink that takes
/// the app down is worse than the silence it replaced.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final defaultCap = Diag.fileCap;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fn-diag');
    Diag.resetForTesting();
    Diag.directoryOverride = root;
  });

  tearDown(() async {
    await Diag.flush();
    Diag.fileCap = defaultCap;
    Diag.directoryOverride = null;
    Diag.resetForTesting();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the ring keeps the last 500, newest first', () async {
    for (var i = 0; i < Diag.ringCap + 100; i++) {
      Diag.report(StateError('boom $i'), StackTrace.current, where: 'T.ring');
    }
    expect(Diag.length, Diag.ringCap);
    final entries = Diag.entries;
    expect(entries.first.message, contains('boom ${Diag.ringCap + 99}'));
    expect(entries.last.message, contains('boom 100'));
    expect(entries.first.where, 'T.ring');
    expect(entries.first.frames, isNotNull);
    // Frames are trimmed, not the whole trace.
    expect(entries.first.frames!.split('\n').length, lessThanOrEqualTo(6));
    await Diag.flush();
  });

  test('log lines carry no frames; extra lands in the message', () async {
    Diag.log('launch', where: 'main');
    Diag.report(
      'bad file',
      null,
      where: 'Restore.apply',
      extra: {'path': '/x/y', 'n': 3},
    );
    final entries = Diag.entries;
    expect(entries[1].message, 'launch');
    expect(entries[1].frames, isNull);
    expect(entries[0].message, contains('bad file'));
    expect(entries[0].message, contains('path=/x/y'));
    expect(entries[0].message, contains('n=3'));
    await Diag.flush();
  });

  test(
    'entries are appended to diag.log under the support directory',
    () async {
      Diag.log('first', where: 'T.file');
      Diag.report(ArgumentError('second'), StackTrace.current, where: 'T.file');
      await Diag.flush();
      final f = File(p.join(root.path, Diag.fileName));
      expect(f.existsSync(), isTrue);
      final text = f.readAsStringSync();
      expect(text, contains('T.file  first'));
      expect(text, contains('second'));
      // The two are in write order and each ends its own line.
      expect(text.indexOf('first'), lessThan(text.indexOf('second')));
      expect(text.endsWith('\n'), isTrue);
    },
  );

  test('the file rolls over once at the cap and keeps one .1', () async {
    Diag.fileCap = 600;
    for (var i = 0; i < 40; i++) {
      Diag.log('line $i padded to make it longer than a few bytes', where: 'T');
    }
    await Diag.flush();
    final f = File(p.join(root.path, Diag.fileName));
    final old = File('${f.path}.1');
    expect(f.existsSync(), isTrue);
    expect(old.existsSync(), isTrue);
    // Neither side grows past the cap by more than one line.
    expect(f.lengthSync(), lessThan(Diag.fileCap + 120));
    expect(old.lengthSync(), lessThan(Diag.fileCap + 120));
    // The newest line is in the live file, never in the rotation.
    expect(f.readAsStringSync(), contains('line 39'));
    expect(old.readAsStringSync(), isNot(contains('line 39')));
    // And there is exactly one rotation, not a .2.
    expect(File('${f.path}.2').existsSync(), isFalse);
  });

  test('clear empties the ring and the live file', () async {
    Diag.log('gone', where: 'T.clear');
    await Diag.flush();
    await Diag.clear();
    expect(Diag.length, 0);
    final f = File(p.join(root.path, Diag.fileName));
    expect(f.readAsStringSync(), isEmpty);
  });

  test('an unwritable directory never throws; the ring still has it', () async {
    // A path under a regular file cannot be a directory.
    final blocker = File(p.join(root.path, 'blocker'))..writeAsStringSync('x');
    Diag.resetForTesting();
    Diag.directoryOverride = Directory(p.join(blocker.path, 'nope'));
    expect(
      () => Diag.log('still here', where: 'T.unwritable'),
      returnsNormally,
    );
    expect(
      () => Diag.report(Exception('x'), StackTrace.current, where: 'T.u'),
      returnsNormally,
    );
    await expectLater(Diag.flush(), completes);
    await expectLater(Diag.clear(), completes);
    // clear() is allowed to forget; before it ran the ring had both.
    Diag.log('after', where: 'T.unwritable');
    expect(Diag.entries.first.message, 'after');
    await Diag.flush();
  });

  test('an error whose toString throws is still recorded', () {
    expect(
      () => Diag.report(_Hostile(), StackTrace.current, where: 'T.hostile'),
      returnsNormally,
    );
    expect(Diag.entries.first.message, contains('_Hostile'));
  });

  test('install forwards to the previous FlutterError.onError', () async {
    final before = FlutterError.onError;
    FlutterErrorDetails? seen;
    FlutterError.onError = (d) => seen = d;
    try {
      Diag.install();
      final details = FlutterErrorDetails(
        exception: StateError('render'),
        library: 'widgets',
      );
      FlutterError.onError!(details);
      expect(seen, same(details), reason: 'the earlier handler still runs');
      final e = Diag.entries.first;
      expect(e.where, 'FlutterError');
      expect(e.message, contains('render'));
      expect(e.message, contains('library=widgets'));
    } finally {
      FlutterError.onError = before;
    }
    await Diag.flush();
  });

  test('install forwards to the previous PlatformDispatcher.onError', () async {
    final dispatcher = PlatformDispatcher.instance;
    final before = dispatcher.onError;
    Object? seen;
    dispatcher.onError = (e, s) {
      seen = e;
      return true;
    };
    try {
      Diag.install();
      final err = Exception('async');
      final handled = dispatcher.onError!(err, StackTrace.current);
      expect(handled, isTrue, reason: 'the earlier verdict is kept');
      expect(seen, same(err));
      expect(Diag.entries.first.where, 'PlatformDispatcher');
    } finally {
      dispatcher.onError = before;
    }
    await Diag.flush();
  });

  test(
    'with no previous PlatformDispatcher handler, install says unhandled',
    () async {
      final dispatcher = PlatformDispatcher.instance;
      final before = dispatcher.onError;
      dispatcher.onError = null;
      try {
        Diag.install();
        expect(
          dispatcher.onError!(Exception('x'), StackTrace.current),
          isFalse,
        );
      } finally {
        dispatcher.onError = before;
      }
      await Diag.flush();
    },
  );
}

class _Hostile {
  @override
  String toString() => throw StateError('no');
}
