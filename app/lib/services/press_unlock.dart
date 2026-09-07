import 'package:flutter/material.dart';

import '../theme/skin.dart';
import 'app_prefs.dart';

/// Seven taps on the version row wakes the press (D-023) — the Android
/// developer-options gesture: the curious find it, nobody trips it. One
/// counter, one teaser, one reveal, for the phone's Settings tab and the
/// desk's Settings workspace alike.
class PressUnlock {
  PressUnlock(this.prefs);
  final AppPrefs prefs;
  int _taps = 0;

  /// Set when the unlock flips the skin: the flip re-keys the root
  /// MaterialApp, which destroys the ScaffoldMessenger the toast would
  /// have shown on — a toast shown from the tapping tree never draws.
  /// The successor tree asks with [takePending] and delivers the reveal
  /// itself.
  static bool _pending = false;

  /// A tap on the version row: a countdown from the fourth, the flip on
  /// the seventh.
  void tap(BuildContext context) {
    if (prefs.pressUnlocked) return; // already found; just a version row
    _taps++;
    if (_taps < 7) {
      if (_taps >= 4) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('${7 - _taps} more…'),
              duration: const Duration(milliseconds: 700),
            ),
          );
      }
      return;
    }
    _pending = true;
    prefs.pressUnlocked = true;
    prefs.skinName = 'press'; // notifies → root rebuild
  }

  /// True exactly once after the seventh tap: whoever is built first in
  /// the successor tree owns the reveal.
  static bool takePending() {
    final p = _pending;
    _pending = false;
    return p;
  }

  /// The reveal, first frame of the successor tree. It speaks in the
  /// voice just found — these values are the press's own, not the active
  /// skin's, so the toast IS the easter egg whatever the app is wearing.
  static void reveal(State state) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!state.mounted) return;
      ScaffoldMessenger.of(state.context).showSnackBar(
        SnackBar(
          backgroundColor: pressSkin.ink,
          duration: const Duration(seconds: 6),
          content: Text(
            '◆ YOU FOUND THE PRESS — SHORT\'S RESORT FIELD STATION.\n'
            'SWITCH SKINS ANY TIME UNDER APPEARANCE.',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              letterSpacing: 1.2,
              height: 1.6,
              color: pressSkin.paper,
            ),
          ),
        ),
      );
    });
  }

  static void revealIfPending(State state) {
    if (takePending()) reveal(state);
  }
}
