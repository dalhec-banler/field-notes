import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../db/database.dart';

/// Environmental context enrichment (spec §4.11).
///
/// Rows are created offline with `is_stale = 1` and only coordinates + date;
/// this service backfills weather (Open-Meteo archive, no key) and soil
/// (USDA-NRCS Soil Data Access) when connectivity returns. Soil is cached per
/// mukey — the soil under a point does not change. SDA is single-threaded
/// upstream, so requests run strictly one at a time with a courtesy delay.
class EnvContextService {
  EnvContextService(
    this.db, {
    http.Client? client,
    this.courtesyDelay = const Duration(seconds: 1),
  }) : _client = client ?? http.Client();

  final FieldNotesDb db;
  final http.Client _client;
  final Duration courtesyDelay;

  static const _openMeteo = 'archive-api.open-meteo.com';
  static const _sdaUrl =
      'https://SDMDataAccess.sc.egov.usda.gov/Tabular/post.rest';

  final Map<String, Map<String, Object?>> _soilCache = {};

  /// Creates a stale context row for a capture. Never blocks; call and forget.
  Future<String> createStale({
    required String propertyId,
    required double lat,
    required double lng,
    required String resolvedFor, // YYYY-MM-DD
  }) async {
    final id = newId();
    final now = nowUtcIso();
    await db.into(db.envContexts).insert(EnvContextsCompanion.insert(
          id: id,
          propertyId: propertyId,
          lat: lat,
          lng: lng,
          resolvedFor: resolvedFor,
          isStale: const Value(1),
          createdAt: now,
          updatedAt: now,
        ));
    return id;
  }

  /// Backfills every stale row. Returns how many were completed.
  Future<int> backfillStale() async {
    final stale = await (db.select(db.envContexts)
          ..where((e) => e.isStale.equals(1))
          ..limit(50))
        .get();
    var done = 0;
    for (final row in stale) {
      try {
        final weather =
            await _fetchWeather(row.lat, row.lng, row.resolvedFor);
        final soil = await _fetchSoil(row.lat, row.lng);
        await (db.update(db.envContexts)..where((e) => e.id.equals(row.id)))
            .write(EnvContextsCompanion(
          tempMinC: Value(weather['temp_min_c'] as double?),
          tempMaxC: Value(weather['temp_max_c'] as double?),
          precip24hMm: Value(weather['precip_24h_mm'] as double?),
          precip7dMm: Value(weather['precip_7d_mm'] as double?),
          precip30dMm: Value(weather['precip_30d_mm'] as double?),
          daysSinceRain: Value(weather['days_since_rain'] as int?),
          soilMukey: Value(soil?['mukey'] as String?),
          soilSeries: Value(soil?['series'] as String?),
          soilTexture: Value(soil?['texture'] as String?),
          soilDrainageClass: Value(soil?['drainage'] as String?),
          sourceJson: Value(jsonEncode({'weather': weather, 'soil': soil})),
          fetchedAt: Value(nowUtcIso()),
          isStale: const Value(0),
          updatedAt: Value(nowUtcIso()),
        ));
        done++;
        await Future<void>.delayed(courtesyDelay);
      } catch (_) {
        // Leave stale; a later pass retries. Offline must never error loudly.
      }
    }
    return done;
  }

  /// Open-Meteo archive: daily min/max temp and precip for the 30 days ending
  /// on [date]; derives 24h/7d/30d totals and days since rain.
  Future<Map<String, Object?>> _fetchWeather(
      double lat, double lng, String date) async {
    final end = DateTime.parse(date);
    final start = end.subtract(const Duration(days: 29));
    String d(DateTime t) => t.toIso8601String().substring(0, 10);
    final uri = Uri.https(_openMeteo, '/v1/archive', {
      'latitude': '$lat',
      'longitude': '$lng',
      'start_date': d(start),
      'end_date': d(end),
      'daily': 'temperature_2m_min,temperature_2m_max,precipitation_sum',
      'timezone': 'auto',
    });
    final res = await _client.get(uri);
    if (res.statusCode != 200) {
      throw http.ClientException('Open-Meteo ${res.statusCode}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final daily = data['daily'] as Map<String, dynamic>;
    final rawPrecip = (daily['precipitation_sum'] as List)
        .map((v) => (v as num?)?.toDouble())
        .toList();
    // The archive lags real time by a few days; trailing nulls mean "not
    // yet", not "dry". Committing them as 0 mm would write a false "N days
    // since rain" and clear the stale flag for good. Stay stale, retry later.
    if (rawPrecip.isEmpty || rawPrecip.last == null) {
      throw StateError('Open-Meteo archive not caught up to $date');
    }
    final precip = rawPrecip.map((v) => v ?? 0.0).toList();
    final tmin = (daily['temperature_2m_min'] as List)
        .map((v) => (v as num?)?.toDouble())
        .toList();
    final tmax = (daily['temperature_2m_max'] as List)
        .map((v) => (v as num?)?.toDouble())
        .toList();

    double sumLast(int days) => precip.length < days
        ? precip.fold(0.0, (a, b) => a + b)
        : precip.sublist(precip.length - days).fold(0.0, (a, b) => a + b);
    int daysSinceRain() {
      for (var i = precip.length - 1; i >= 0; i--) {
        if (precip[i] > 1.0) return precip.length - 1 - i;
      }
      return precip.length;
    }

    return {
      'temp_min_c': tmin.isEmpty ? null : tmin.last,
      'temp_max_c': tmax.isEmpty ? null : tmax.last,
      'precip_24h_mm': sumLast(1),
      'precip_7d_mm': sumLast(7),
      'precip_30d_mm': sumLast(30),
      'days_since_rain': daysSinceRain(),
    };
  }

  /// NRCS Soil Data Access: dominant component for the map unit at the point.
  Future<Map<String, Object?>?> _fetchSoil(double lat, double lng) async {
    // Cache by rounded coordinate first (points within ~100 m share soil
    // lookups), then by mukey server-side semantics.
    final cacheKey = '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';
    final cached = _soilCache[cacheKey];
    if (cached != null) return cached;

    final query = """
SELECT TOP 1 mu.mukey, c.compname, c.taxpartsize, c.drainagecl
FROM mapunit mu
JOIN component c ON c.mukey = mu.mukey AND c.majcompflag = 'Yes'
WHERE mu.mukey IN (
  SELECT * FROM SDA_Get_Mukey_from_intersection_with_WktWgs84('point($lng $lat)')
)
ORDER BY c.comppct_r DESC""";
    final res = await _client.post(
      Uri.parse(_sdaUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'query': query, 'format': 'JSON'}),
    );
    if (res.statusCode != 200) {
      // A down SDA is a retry, not "no soil here".
      throw http.ClientException('SDA ${res.statusCode}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final table = data['Table'] as List?;
    if (table == null || table.isEmpty) return null;
    final row = table.first as List;
    final soil = {
      'mukey': '${row[0]}',
      'series': row[1] as String?,
      'texture': row[2] as String?,
      'drainage': row[3] as String?,
    };
    _soilCache[cacheKey] = soil;
    return soil;
  }
}
