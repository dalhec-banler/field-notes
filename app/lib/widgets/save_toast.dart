import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'press.dart';

/// The save toast (design README §3.8), drawn as an app-level overlay rather
/// than a SnackBar. A SnackBar's auto-dismiss proved unreliable on device
/// (observed sitting for minutes across every tab) and it migrates onto
/// whichever Scaffold is current; this one owns its own timer and dismisses
/// itself, undo or not.
class SaveToast {
  SaveToast._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(
    BuildContext context, {
    required String title,
    required String detail,
    required Future<void> Function() onUndo,
    // Optional second action (audit U1: "identify" belongs at the moment of
    // saving, not buried a screen deep). Tapping it dismisses the toast.
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 5),
  }) {
    dismiss();
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _ToastBody(
        title: title,
        detail: detail,
        actionLabel: actionLabel,
        onAction: onAction == null
            ? null
            : () {
                dismiss();
                onAction();
              },
        onUndo: () async {
          dismiss();
          // Grab the messenger before the await; the overlay outlives any
          // one screen, so this is the right owner for the failure note.
          final messenger = ScaffoldMessenger.maybeOf(overlay.context);
          try {
            await onUndo();
          } catch (e) {
            // The record is still there; say so rather than fail silently.
            messenger?.showSnackBar(
              SnackBar(content: Text('Undo failed — record kept. $e')),
            );
          }
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(duration, dismiss);
  }

  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    final entry = _entry;
    _entry = null;
    if (entry != null) {
      entry.remove();
      entry.dispose();
    }
  }
}

class _ToastBody extends StatelessWidget {
  const _ToastBody({
    required this.title,
    required this.detail,
    required this.onUndo,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String detail;
  final Future<void> Function() onUndo;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: Metrics.gutter,
      right: Metrics.gutter,
      // Clear the five-tab bar and the capture FAB.
      bottom: bottomInset + 96,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            color: Press.ink,
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MonoLabel(
                      title,
                      size: 10,
                      spacing: 1.2,
                      color: Press.paperRaised,
                    ),
                    const SizedBox(height: 4),
                    MonoLabel(
                      detail,
                      size: 9.5,
                      spacing: 1.0,
                      color: Press.sageLight,
                    ),
                  ],
                ),
              ),
              if (actionLabel != null && onAction != null)
                TextButton(
                  onPressed: onAction,
                  child: MonoLabel(
                    actionLabel!,
                    size: 10.5,
                    spacing: 1.6,
                    color: Press.sageLight,
                  ),
                ),
              TextButton(
                onPressed: onUndo,
                child: MonoLabel(
                  'UNDO',
                  size: 10.5,
                  spacing: 1.6,
                  color: Press.gold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
