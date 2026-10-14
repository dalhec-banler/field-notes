part of '../oplog.dart';

// ── the logical clock ────────────────────────────────────────────

/// Fixed width so text order IS chronological order, whatever the
/// precision of anybody's timestamps.
String _stamp(int phys, int ctr) =>
    '${phys.toString().padLeft(15, '0')}-${ctr.toString().padLeft(6, '0')}';

int _physOf(String version) => int.tryParse(version.split('-').first) ?? 0;

int _ctrOf(String version) {
  final parts = version.split('-');
  return parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
}

mixin _OpLogClock on _OpLogCore {
  Future<(int, int)> _readClock() async {
    final row = await db
        .customSelect('SELECT phys, ctr FROM sync_clock WHERE id = 0')
        .getSingleOrNull();
    if (row == null) return (0, 0);
    return (row.data['phys'] as int, row.data['ctr'] as int);
  }

  Future<void> _writeClock(int phys, int ctr) => db.customStatement(
    'INSERT OR REPLACE INTO sync_clock (id, phys, ctr) VALUES (0, ?, ?)',
    [phys, ctr],
  );

  /// The next version this device may stamp. Never goes backwards, even
  /// if the operating system's clock does.
  Future<String> _nextVersion() async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final (phys, ctr) = await _readClock();
    final nextPhys = now > phys ? now : phys;
    final nextCtr = now > phys ? 0 : ctr + 1;
    await _writeClock(nextPhys, nextCtr);
    return _stamp(nextPhys, nextCtr);
  }

  /// Learn from a version seen from a peer, so anything this device
  /// stamps afterwards sorts after it.
  Future<void> _observe(String version) async {
    final rPhys = _physOf(version);
    final rCtr = _ctrOf(version);
    final (phys, ctr) = await _readClock();
    if (rPhys > phys || (rPhys == phys && rCtr > ctr)) {
      await _writeClock(rPhys, rCtr);
    }
  }
}
