part of '../desktop_shell.dart';

/// The shell's state: which workspace is up, the status figures, Drive
/// news and the sync clock.
mixin _DesktopShellCore on State<DesktopShell> {
  int _view = 0;

  int _dbBytes = 0;
  int _mediaCount = 0;
  List<Property> _properties = const [];

  /// The phone has put a newer copy in Drive than the one this desk holds.
  DriveNews? _news;

  StreamSubscription<void>? _statusWatch;
  Timer? _statusDebounce;

  /// D-028: what this desk has that the phone doesn't yet, and when the
  /// two last spoke. Sync runs on open, on focus, and every few minutes.
  int _pendingSync = 0;
  String? _lastSync;
  bool _syncing = false;
  Timer? _syncTimer;

  String _copyLine = '';
}
