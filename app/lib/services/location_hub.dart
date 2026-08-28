import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Single owner of the platform position stream.
///
/// `geolocator_android` caches ONE platform stream and the first subscriber's
/// settings win for everyone until the last subscriber cancels. If the map
/// subscribes first with plain settings, a later "log track" request never
/// gets its foreground service or wake lock. Every consumer in the app
/// therefore listens to [positions] here; only this class talks to
/// `Geolocator.getPositionStream`, and switching to foreground mode tears the
/// platform stream down and re-creates it with the foreground config.
///
/// All platform (re)starts are serialized through one queue and stamped with
/// a generation, so overlapping requests (a listener attaching while a
/// foreground switch is mid-await) can never leave two subscriptions alive.
class LocationHub extends ChangeNotifier {
  LocationHub();

  Position? _last;

  /// Most recent fix, or null. See [fresh] for a staleness-checked read.
  Position? get last => _last;

  /// [last] only if it arrived within [maxAge]; a fix from before the app
  /// idled is not a fix.
  Position? fresh({Duration maxAge = const Duration(seconds: 60)}) {
    final p = _last;
    if (p == null) return null;
    return DateTime.now().difference(p.timestamp) <= maxAge ? p : null;
  }

  bool _foreground = false;
  bool get foreground => _foreground;

  String? lastError;

  StreamSubscription<Position>? _platformSub;
  Future<void> _queue = Future.value();
  int _gen = 0;
  Timer? _retry;

  late final StreamController<Position> _controller =
      StreamController<Position>.broadcast(
    onListen: _syncPlatform,
    onCancel: _syncPlatform,
  );

  /// Live fixes. Subscribing starts the platform stream on demand; the last
  /// cancel stops it unless a track is being recorded. Errors are NOT
  /// forwarded — the hub owns recovery; read [lastError] if you care.
  Stream<Position> get positions => _controller.stream;

  /// Check, and if needed request, location permission.
  Future<bool> ensurePermission({bool request = true}) async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && request) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (e) {
      lastError = '$e';
      return false;
    }
  }

  /// Foreground mode = Android foreground service + persistent notification
  /// + wake lock, 5 s / 10 m sampling (spec §4.13). Restarts the platform
  /// stream so the new settings actually reach the OS. Awaits the restart.
  Future<void> setForeground(bool on) async {
    if (_foreground == on) return;
    _foreground = on;
    await _restart();
    notifyListeners();
  }

  LocationSettings get _settings {
    if (_foreground && Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Field Notes is recording your walk',
          notificationText: 'Track logging is on. Tap stop in the app.',
          notificationIcon:
              AndroidResource(name: 'launch_background', defType: 'drawable'),
          enableWakeLock: true,
        ),
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best);
  }

  bool get _wanted => _foreground || _controller.hasListener;

  void _syncPlatform() {
    if (_wanted != (_platformSub != null)) _restart();
  }

  /// Tear down whatever is running and, if anything still wants positions,
  /// start again with the current settings. Serialized; a newer request
  /// supersedes an older one that hasn't reached the start step yet.
  Future<void> _restart() {
    final gen = ++_gen;
    _retry?.cancel();
    _retry = null;
    // A failed step must never poison the queue for the life of the process;
    // every later restart still runs.
    return _queue = _queue.catchError((_) {}).then((_) async {
      final old = _platformSub;
      _platformSub = null;
      try {
        await old?.cancel();
      } catch (_) {}
      if (gen != _gen || !_wanted) return;
      try {
        _platformSub =
            Geolocator.getPositionStream(locationSettings: _settings).listen(
          (pos) {
            _last = pos;
            lastError = null;
            if (!_controller.isClosed) _controller.add(pos);
            notifyListeners();
          },
          onError: _onPlatformError,
        );
      } catch (e) {
        _onPlatformError(e);
      }
    });
  }

  /// GPS toggled off, service died, permission revoked: drop the dead
  /// subscription so a later sync can start a new one, and retry on a
  /// backoff while anyone still wants fixes.
  void _onPlatformError(Object e) {
    lastError = '$e';
    final dead = _platformSub;
    _platformSub = null;
    dead?.cancel();
    notifyListeners();
    _retry?.cancel();
    // Denied-forever won't change on its own; don't loop asking the OS.
    if (e is PermissionDeniedException) return;
    _retry = Timer(const Duration(seconds: 10), () {
      _retry = null;
      if (_wanted && _platformSub == null) _restart();
    });
  }

  @override
  void dispose() {
    _retry?.cancel();
    _platformSub?.cancel();
    _controller.close();
    super.dispose();
  }
}
