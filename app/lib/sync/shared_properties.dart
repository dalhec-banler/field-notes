import 'dart:convert';

import '../services/app_prefs.dart';

/// A property this device exchanges through the relay (D-031). Lives in
/// prefs beside the Drive grant: not synced, not backed up — a restored
/// phone rejoins with a code, and a stolen backup carries no token.
class SharedProperty {
  const SharedProperty({
    required this.propertyId,
    required this.name,
    required this.relayUrl,
    required this.memberToken,
    required this.role,
    this.badgeName,
    this.paused = false,
  });

  final String propertyId;
  final String name;
  final String relayUrl;
  final String memberToken;

  /// owner | editor | viewer.
  final String role;
  final String? badgeName;

  /// Left alone by the automatic runner (a removed member, a seat limit)
  /// until a person opens the property's sync screen.
  final bool paused;

  bool get canWrite => role != 'viewer';

  SharedProperty copyWith({
    String? name,
    String? badgeName,
    bool clearBadge = false,
    bool? paused,
  }) => SharedProperty(
    propertyId: propertyId,
    name: name ?? this.name,
    relayUrl: relayUrl,
    memberToken: memberToken,
    role: role,
    badgeName: clearBadge ? null : (badgeName ?? this.badgeName),
    paused: paused ?? this.paused,
  );

  Map<String, Object?> toJson() => {
    'property_id': propertyId,
    'name': name,
    'relay_url': relayUrl,
    'member_token': memberToken,
    'role': role,
    if (badgeName != null) 'badge_name': badgeName,
    if (paused) 'paused': true,
  };

  factory SharedProperty.fromJson(Map<String, dynamic> j) => SharedProperty(
    propertyId: j['property_id'] as String,
    name: j['name'] as String,
    relayUrl: j['relay_url'] as String,
    memberToken: j['member_token'] as String,
    role: j['role'] as String,
    badgeName: j['badge_name'] as String?,
    paused: j['paused'] == true,
  );
}

/// The list of shared properties in prefs, as one JSON string under
/// `shared_properties`.
extension SharedPropertiesPrefs on AppPrefs {
  static const _key = 'shared_properties';

  List<SharedProperty> get sharedProperties {
    final raw = get<String>(_key);
    if (raw == null) return const [];
    try {
      return [
        for (final j in (jsonDecode(raw) as List).cast<Map<String, dynamic>>())
          SharedProperty.fromJson(j),
      ];
    } catch (_) {
      return const [];
    }
  }

  SharedProperty? sharedProperty(String propertyId) {
    for (final s in sharedProperties) {
      if (s.propertyId == propertyId) return s;
    }
    return null;
  }

  /// Adds or replaces by property id.
  void putSharedProperty(SharedProperty s) {
    final all = [
      for (final x in sharedProperties)
        if (x.propertyId != s.propertyId) x,
      s,
    ];
    set(_key, jsonEncode([for (final x in all) x.toJson()]));
  }

  void removeSharedProperty(String propertyId) {
    final all = [
      for (final x in sharedProperties)
        if (x.propertyId != propertyId) x,
    ];
    set(
      _key,
      all.isEmpty ? null : jsonEncode([for (final x in all) x.toJson()]),
    );
  }
}
