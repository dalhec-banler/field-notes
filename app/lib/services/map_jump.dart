import 'package:flutter/foundation.dart';

import '../app_scope.dart';

/// A request to show one spot on one place's map — from a batch's mother
/// plant, a planting on another property, anywhere that names ground on a
/// map other than the one open (D-029). The shell switches place and tab;
/// the map flies there once its controller is up, then clears the request.
class MapJump {
  const MapJump({
    required this.propertyId,
    required this.lat,
    required this.lng,
    this.recordId,
  });

  final String propertyId;
  final double lat;
  final double lng;

  /// The record to light up on arrival, when the spot is a record.
  final String? recordId;
}

/// The notifier the process started with — see [recordFilter]'s twin.
final _processJump = ValueNotifier<MapJump?>(null);

/// The one pending jump. Set it; the shell and the map take it from here.
/// LEGACY: a delegate to `AppScope.current.mapJump`; new code reads
/// `AppScope.of(context).mapJump` (D-038 item 6).
ValueNotifier<MapJump?> get mapJump =>
    AppScope.maybeCurrent?.mapJump ?? _processJump;
