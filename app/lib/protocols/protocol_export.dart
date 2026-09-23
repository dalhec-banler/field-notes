import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/database.dart';
import 'field_defs.dart';
import 'indicators.dart';

/// Monitoring in the shape an analyst wants (D-033).
///
/// `protocol_runs_long.csv`: one row per site × run × sample × question —
/// tidy, so every tidyverse verb and every ArcGIS join works. Class answers
/// carry both the class and its midpoint so the analyst chooses the
/// transformation. `protocol_runs_wide.csv`: one row per run with the
/// computed indicators as columns — the sheet a biologist pastes into a
/// form. `schema.ini` declares column types so ArcGIS never guesses.
///
/// Share mode is honoured like observations: a fuzzed or zone-only place
/// blanks the coordinates and keeps the zone.
class ProtocolExport {
  ProtocolExport(this.db);

  final FieldNotesDb db;

  static const longHeaders = [
    'property_name',
    'protocol_id',
    'protocol_key',
    'protocol_name',
    'method_name',
    'site_id',
    'site_name',
    'site_kind',
    'zone_name',
    'site_lat',
    'site_lng',
    'site_bearing_deg',
    'site_length_m',
    'site_radius_m',
    'run_id',
    'observation_id',
    'observed_at_utc',
    'observed_at_local',
    'local_tz',
    'observed_date',
    'actual_lat',
    'actual_lng',
    'gps_accuracy_m',
    'observer',
    'run_status',
    'sample_group',
    'sample_index',
    'field_key',
    'field_label',
    'value',
    'value_num',
    'unit',
    'scale',
    'taxon_id',
    'taxon_scientific',
    'taxon_common',
    'usda_symbol',
    'by_key',
    'by_value',
  ];

  Future<void> writeInto(String propertyId, Directory dataDir) async {
    final property = await (db.select(
      db.properties,
    )..where((x) => x.id.equals(propertyId))).getSingleOrNull();
    if (property == null) return;
    final precise = property.defaultShareMode == 'precise';

    final protocols = {
      for (final x in await (db.select(
        db.protocols,
      )..where((x) => x.propertyId.equals(propertyId))).get())
        x.id: x,
    };
    final sites = {
      for (final x in await (db.select(
        db.protocolSites,
      )..where((x) => x.propertyId.equals(propertyId))).get())
        x.id: x,
    };
    final zones = {
      for (final z in await (db.select(
        db.zones,
      )..where((z) => z.propertyId.equals(propertyId))).get())
        z.id: z.name,
    };
    final taxa = {for (final t in await db.select(db.taxa).get()) t.id: t};
    final runs =
        await (db.select(db.protocolRuns)
              ..where((r) => r.propertyId.equals(propertyId))
              ..where((r) => r.deletedAt.isNull()))
            .get();
    final obsIds = runs.map((r) => r.observationId).toSet();
    final observations = {
      for (final o in await db.select(db.observations).get())
        if (obsIds.contains(o.id)) o.id: o,
    };

    final long = StringBuffer()..writeln(longHeaders.join(','));
    final wideRows = <Map<String, Object?>>[];
    final wideKeys = <String>{};

    for (final run in runs) {
      final protocol = protocols[run.protocolId];
      final site = sites[run.siteId];
      if (protocol == null || site == null) continue;
      final obs = observations[run.observationId];
      final fields = _safeFields(protocol.fieldsJson);
      final values = _safeValues(run.valuesJson);
      final located = obs != null && obs.gpsAccuracyM != -1;
      final started = DateTime.tryParse(run.startedAt)?.toUtc();
      final base = <String, Object?>{
        'property_name': property.name,
        'protocol_id': protocol.id,
        'protocol_key': protocol.methodKey,
        'protocol_name': protocol.name,
        'method_name': protocol.methodName,
        'site_id': site.id,
        'site_name': site.name,
        'site_kind': protocol.siteKind,
        'zone_name': zones[site.zoneId],
        'site_lat': precise ? site.lat : null,
        'site_lng': precise ? site.lng : null,
        'site_bearing_deg': site.bearingDeg,
        'site_length_m': site.lengthM,
        'site_radius_m': site.radiusM,
        'run_id': run.id,
        'observation_id': run.observationId,
        'observed_at_utc': run.startedAt,
        'observed_at_local': started?.toLocal().toIso8601String(),
        'local_tz': run.localTz,
        'observed_date': started == null
            ? null
            : started.toLocal().toIso8601String().substring(0, 10),
        'actual_lat': precise && located ? obs.lat : null,
        'actual_lng': precise && located ? obs.lng : null,
        'gps_accuracy_m': obs?.gpsAccuracyM,
        'observer': run.observerName ?? run.createdBy,
        'run_status': run.status,
      };

      void emit(FieldDef f, Object? raw, {String? group, int? index}) {
        final rows = _rowsFor(f, raw, taxa);
        for (final r in rows) {
          final row = {
            ...base,
            'sample_group': group,
            'sample_index': index,
            'field_key': f.key,
            'field_label': f.label,
            ...r,
          };
          long.writeln(longHeaders.map((h) => _cell(row[h])).join(','));
        }
      }

      for (final f in fields) {
        if (f.type == FieldType.group) {
          final samples = values[f.key];
          if (samples is! List) continue;
          for (var i = 0; i < samples.length; i++) {
            final s = samples[i];
            if (s is! Map) continue;
            for (final sub in f.fields) {
              emit(sub, s[sub.key], group: f.key, index: i + 1);
            }
          }
        } else {
          emit(f, values[f.key]);
        }
      }

      final indicators = computeIndicators(
        methodKey: protocol.methodKey,
        valuesJson: run.valuesJson,
        siteKind: protocol.siteKind,
        radiusM: site.radiusM,
        lengthM: site.lengthM,
        nameOf: (id) => taxa[id]?.commonName ?? taxa[id]?.scientificName ?? id,
      );
      final wide = <String, Object?>{
        'property_name': property.name,
        'protocol_key': protocol.methodKey,
        'protocol_name': protocol.name,
        'site_id': site.id,
        'site_name': site.name,
        'zone_name': zones[site.zoneId],
        'run_id': run.id,
        'observed_date': base['observed_date'],
        'observed_at_utc': run.startedAt,
        'observer': base['observer'],
        'run_status': run.status,
      };
      for (final i in indicators) {
        wide[i.key] = i.value;
        if (i.detail != null) wide['${i.key}_detail'] = i.detail;
      }
      wideKeys.addAll(wide.keys);
      wideRows.add(wide);
    }

    File(p.join(dataDir.path, 'protocol_runs_long.csv'))
        .writeAsStringSync(long.toString());

    final wideHeaders = [
      'property_name',
      'protocol_key',
      'protocol_name',
      'site_id',
      'site_name',
      'zone_name',
      'run_id',
      'observed_date',
      'observed_at_utc',
      'observer',
      'run_status',
      ...wideKeys.where(
        (k) => ![
          'property_name',
          'protocol_key',
          'protocol_name',
          'site_id',
          'site_name',
          'zone_name',
          'run_id',
          'observed_date',
          'observed_at_utc',
          'observer',
          'run_status',
        ].contains(k),
      ),
    ];
    final wide = StringBuffer()..writeln(wideHeaders.join(','));
    for (final r in wideRows) {
      wide.writeln(wideHeaders.map((h) => _cell(r[h])).join(','));
    }
    File(p.join(dataDir.path, 'protocol_runs_wide.csv'))
        .writeAsStringSync(wide.toString());

    File(p.join(dataDir.path, 'schema.ini')).writeAsStringSync('''
[protocol_runs_long.csv]
Format=CSVDelimited
ColNameHeader=True
Col10=site_lat Double
Col11=site_lng Double
Col12=site_bearing_deg Double
Col13=site_length_m Double
Col14=site_radius_m Double
Col20=observed_date Date
Col21=actual_lat Double
Col22=actual_lng Double
Col23=gps_accuracy_m Double
Col27=sample_index Integer
Col30=value Text
Col31=value_num Double

[protocol_runs_wide.csv]
Format=CSVDelimited
ColNameHeader=True
Col8=observed_date Date
''');
  }

  /// One long-form row (or several, for lists) for a single answer.
  List<Map<String, Object?>> _rowsFor(
    FieldDef f,
    Object? raw,
    Map<String, TaxaData> taxa,
  ) {
    if (raw == null) return const [];
    Map<String, Object?> taxon(String id) => {
      'taxon_id': id,
      'taxon_scientific': taxa[id]?.scientificName,
      'taxon_common': taxa[id]?.commonName,
      'usda_symbol': taxa[id]?.usdaPlantsSymbol,
    };
    switch (f.type) {
      case FieldType.class_:
        final scale = f.scale;
        return [
          {
            'value': '$raw',
            'value_num': classValue(scale, raw),
            'unit': '$raw' == absentCode
                ? (scales[scale]?.unit ?? 'class')
                : (scales[scale]?.unit ?? 'class'),
            'scale': scale,
          },
        ];
      case FieldType.int_:
      case FieldType.real:
        final n = raw is num ? raw : num.tryParse('$raw');
        return [
          {'value': '$raw', 'value_num': n, 'unit': f.unit ?? 'number'},
        ];
      case FieldType.bool_:
        return [
          {'value': '$raw', 'value_num': raw == true ? 1 : 0, 'unit': 'bool'},
        ];
      case FieldType.taxa:
        final ids = raw is List ? raw : [raw];
        return [
          for (final id in ids)
            {
              'value': taxa['$id']?.scientificName ?? '$id',
              'unit': 'taxon',
              ...taxon('$id'),
            },
        ];
      case FieldType.countByTaxon:
        if (raw is! List) return const [];
        return [
          for (final r in raw)
            if (r is Map && r['taxon_id'] != null)
              {
                'value':
                    taxa['${r['taxon_id']}']?.scientificName ??
                    '${r['taxon_id']}',
                'value_num': r['count'] is num
                    ? r['count']
                    : num.tryParse('${r['count']}'),
                'unit': 'count',
                ...taxon('${r['taxon_id']}'),
                'by_key': f.by,
                'by_value': r['by'],
              },
        ];
      case FieldType.choice:
      case FieldType.text:
      case FieldType.photo:
        return [
          {'value': '$raw', 'unit': typeName(f.type)},
        ];
      case FieldType.group:
        return const [];
    }
  }

  List<FieldDef> _safeFields(String json) {
    try {
      return parseFields(json);
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic> _safeValues(String json) {
    try {
      return (jsonDecode(json) as Map).cast<String, dynamic>();
    } catch (_) {
      return const {};
    }
  }

  String _cell(Object? v) {
    if (v == null) return '';
    final s = v.toString();
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }
}
