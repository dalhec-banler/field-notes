import 'package:connectivity_plus/connectivity_plus.dart';

import 'app_prefs.dart';

/// D-016: users are often off-grid or on metered LTE. Bulk transfers
/// (basemap capture, archive downloads, backup upload) run on Wi-Fi by
/// default; a per-user switch allows cellular. Location is never a network
/// dependency, and small lookups (weather, soil) are always allowed.
class NetworkPolicy {
  NetworkPolicy({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  /// What the phone is on right now.
  Future<NetKind> current() async {
    try {
      final kinds = await _connectivity.checkConnectivity();
      if (kinds.contains(ConnectivityResult.wifi) ||
          kinds.contains(ConnectivityResult.ethernet)) {
        return NetKind.unmetered;
      }
      if (kinds.contains(ConnectivityResult.mobile)) return NetKind.cellular;
      // A VPN masks the underlying transport; on a phone that's as likely
      // LTE as Wi-Fi. Treat it as cellular so the user is asked (D-016).
      if (kinds.contains(ConnectivityResult.vpn)) return NetKind.cellular;
      if (kinds.contains(ConnectivityResult.other)) return NetKind.unmetered;
      return NetKind.none;
    } catch (_) {
      // Unknown platform: don't block the user on a guess.
      return NetKind.unmetered;
    }
  }

  /// Is a bulk download/upload allowed by the user's policy right now?
  Future<BulkVerdict> bulkVerdict(AppPrefs prefs) async {
    final kind = await current();
    return switch (kind) {
      NetKind.unmetered => BulkVerdict.ok,
      NetKind.cellular =>
        prefs.allowCellular ? BulkVerdict.ok : BulkVerdict.cellularBlocked,
      NetKind.none => BulkVerdict.offline,
    };
  }
}

enum NetKind { unmetered, cellular, none }

enum BulkVerdict { ok, cellularBlocked, offline }
