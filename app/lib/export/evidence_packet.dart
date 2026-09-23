import 'dart:io';

import 'package:drift/drift.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../db/database.dart';
import '../services/survival.dart';

/// The evidence packet (audit 2026-08-31, tier 1): one document that puts a
/// cost-share program's field record on an agent's desk — practices,
/// activities with dates and costs, the observations made during the
/// program window, derived survival, and photographs.
///
/// Two rules keep it honest, and they are the product:
///  * Everything in it is derived from records as they were captured.
///    Nothing is typed into the packet itself; there is no field to polish.
///    The footer says so, because that is the claim an agent cares about.
///  * Survival is computed the way the app always computes it (spec §4.8,
///    D-018) — derived, never stored, and never edited for the occasion.
///
/// Pure-Dart `pdf`, so the whole thing is host-testable like the survival
/// report it borrows its bones from.
class EvidencePacket {
  EvidencePacket(this.db);

  final FieldNotesDb db;

  static const _ink = PdfColor.fromInt(0xFF1B1813);
  static const _soft = PdfColor.fromInt(0xFF6B655C);
  static const _rule = PdfColor.fromInt(0xFFB8AE9C);

  /// Photos embedded per packet. Enough to evidence work; small enough to
  /// email. The count of photos NOT included is always printed, so the cap
  /// never silently misrepresents the record.
  static const maxPhotos = 12;

  Future<Uint8List> build(Property property, Program program) async {
    final practices =
        await (db.select(db.practices)
              ..where((x) => x.programId.equals(program.id))
              ..where((x) => x.deletedAt.isNull())
              ..orderBy([(x) => OrderingTerm.asc(x.dueOn)]))
            .get();
    final activities = practices.isEmpty
        ? <PracticeActivity>[]
        : await (db.select(db.practiceActivities)
                ..where(
                  (x) => x.practiceId.isIn([for (final p in practices) p.id]),
                )
                ..where((x) => x.deletedAt.isNull())
                ..orderBy([(x) => OrderingTerm.asc(x.occurredOn)]))
              .get();
    final zones = {
      for (final z in await (db.select(
        db.zones,
      )..where((z) => z.propertyId.equals(property.id))).get())
        z.id: z.name,
    };

    // Observations inside the program window. No window on the program →
    // the property's whole record is the window, and the packet says so.
    final from = program.startsOn;
    final to = program.endsOn;
    var obsQ = db.select(db.observations)
      ..where((o) => o.propertyId.equals(property.id))
      ..where((o) => o.deletedAt.isNull())
      ..orderBy([(o) => OrderingTerm.asc(o.observedAt)]);
    if (from != null) {
      obsQ = obsQ..where((o) => o.observedAt.isBiggerOrEqualValue(from));
    }
    if (to != null) {
      obsQ = obsQ
        ..where((o) => o.observedAt.isSmallerOrEqualValue('${to}T23:59:59Z'));
    }
    final observations = await obsQ.get();

    // Survival over planting events in the same window (cohort figures only,
    // per D-018 — tag samples don't pretend to be rates here).
    final events =
        await (db.select(db.plantingEvents)
              ..where((e) => e.propertyId.equals(property.id))
              ..where((e) => e.deletedAt.isNull()))
            .get();
    final windowed = [
      for (final e in events)
        if ((from == null || e.plantedOn.compareTo(from) >= 0) &&
            (to == null || e.plantedOn.compareTo(to) <= 0))
          e,
    ];
    var planted = 0, aliveKnown = 0, plantedKnown = 0;
    for (final e in windowed) {
      planted += e.countPlanted;
      final s = await survivalFor(db, e);
      if (s != null && !s.fromTags) {
        aliveKnown += s.alive;
        plantedKnown += s.total;
      }
    }

    // Photos linked to the windowed observations, oldest first — the story
    // in the order it happened.
    final photoFiles = <(String date, File file)>[];
    var linkedPhotoCount = 0;
    if (observations.isNotEmpty) {
      final links =
          await (db.select(db.mediaLinks)
                ..where((l) => l.entityType.equals('observation'))
                ..where(
                  (l) => l.entityId.isIn([for (final o in observations) o.id]),
                )
                ..where((l) => l.deletedAt.isNull()))
              .get();
      final byId = {for (final o in observations) o.id: o};
      final mediaIds = [for (final l in links) l.mediaId];
      if (mediaIds.isNotEmpty) {
        final media =
            await (db.select(db.media)
                  ..where((m) => m.id.isIn(mediaIds))
                  ..where((m) => m.mediaType.equals('photo'))
                  // The canonical meaning of "the record's photos"
                  // (observationPhotoFiles) excludes soft-deleted media;
                  // the packet must agree.
                  ..where((m) => m.deletedAt.isNull()))
                .get();
        final mediaById = {for (final m in media) m.id: m};
        final dated = <(String, File)>[];
        for (final l in links) {
          final m = mediaById[l.mediaId];
          final o = byId[l.entityId];
          if (m == null || o == null || m.localPath == null) continue;
          final f = File(m.localPath!);
          if (!f.existsSync()) continue;
          dated.add((o.observedAt.substring(0, 10), f));
        }
        dated.sort((a, b) => a.$1.compareTo(b.$1));
        linkedPhotoCount = dated.length;
        photoFiles.addAll(dated.take(maxPhotos));
      }
    }

    final doc = pw.Document();
    pw.Widget label(String t) => pw.Text(
      t.toUpperCase(),
      style: pw.TextStyle(fontSize: 7, letterSpacing: 1.4, color: _soft),
    );
    pw.Widget rule() => pw.Container(
      margin: const pw.EdgeInsets.symmetric(vertical: 8),
      height: 0.8,
      color: _rule,
    );

    String amount(double? v) =>
        v == null ? '—' : (v == v.roundToDouble() ? '${v.round()}' : '$v');
    final costTotal = activities.fold<double>(
      0,
      (sum, a) => sum + (a.costUsd ?? 0),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(46),
        footer: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            rule(),
            pw.Text(
              'Generated from field records as captured, unedited, by Field '
              'Notes on ${nowUtcIso().substring(0, 10)}. Survival figures are '
              'derived from check-ins, never entered by hand. '
              'Page ${ctx.pageNumber} of ${ctx.pagesCount}.',
              style: pw.TextStyle(fontSize: 7, color: _soft),
            ),
          ],
        ),
        build: (ctx) => [
          // ---- Header ----
          pw.Text(
            'EVIDENCE PACKET',
            style: pw.TextStyle(fontSize: 9, letterSpacing: 3, color: _soft),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            program.name,
            style: pw.TextStyle(
              fontSize: 22,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            [
              if (program.agency != null) program.agency!,
              if (program.contractRef != null)
                'Contract ${program.contractRef}',
            ].join(' · '),
            style: pw.TextStyle(fontSize: 10, color: _soft),
          ),
          pw.SizedBox(height: 10),
          pw.Row(
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    label('Property'),
                    pw.Text(
                      property.name,
                      style: const pw.TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    label('Program window'),
                    pw.Text(
                      from == null && to == null
                          ? 'Whole property record'
                          : '${from ?? '…'} → ${to ?? 'ongoing'}',
                      style: const pw.TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (program.contactName != null)
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      label('Agency contact'),
                      pw.Text(
                        [
                          program.contactName!,
                          if (program.contactEmail != null)
                            program.contactEmail!,
                        ].join('\n'),
                        style: const pw.TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          rule(),

          // ---- Practices ----
          label('Practices'),
          pw.SizedBox(height: 4),
          if (practices.isEmpty)
            pw.Text(
              'No practices recorded against this program.',
              style: const pw.TextStyle(fontSize: 10),
            ),
          if (practices.isNotEmpty)
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: _ink,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColor.fromInt(0xFFEDE7D8),
              ),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 4,
              ),
              headers: [
                'Code',
                'Practice',
                'Zone',
                'Planned',
                'Done',
                'Status',
                'Due / done',
              ],
              data: [
                for (final x in practices)
                  [
                    x.practiceCode ?? '—',
                    x.name,
                    x.zoneId == null ? '—' : (zones[x.zoneId] ?? '—'),
                    '${amount(x.plannedAmount)} ${x.unit ?? ''}'.trim(),
                    '${amount(x.completedAmount)} ${x.unit ?? ''}'.trim(),
                    x.status ?? '—',
                    x.completedOn ?? x.dueOn ?? '—',
                  ],
              ],
            ),
          pw.SizedBox(height: 10),

          // ---- Activities ----
          if (activities.isNotEmpty) ...[
            label('Work performed'),
            pw.SizedBox(height: 4),
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: _ink,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColor.fromInt(0xFFEDE7D8),
              ),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 4,
              ),
              headers: ['Date', 'Activity', 'Amount', 'Cost', 'Contractor'],
              data: [
                for (final a in activities)
                  [
                    a.occurredOn,
                    a.activityType ?? '—',
                    a.amount == null
                        ? '—'
                        : '${amount(a.amount)} ${a.unit ?? ''}'.trim(),
                    a.costUsd == null
                        ? '—'
                        : '\$${a.costUsd!.toStringAsFixed(2)}',
                    a.contractor ?? '—',
                  ],
              ],
            ),
            if (costTotal > 0)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 4),
                child: pw.Text(
                  'Recorded cost total: \$${costTotal.toStringAsFixed(2)}',
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            pw.SizedBox(height: 10),
          ],

          // ---- Field record ----
          label('Field record in window'),
          pw.SizedBox(height: 4),
          pw.Text(
            '${observations.length} observation${observations.length == 1 ? '' : 's'}'
            '${windowed.isEmpty ? '' : ' · ${windowed.length} planting event${windowed.length == 1 ? '' : 's'}, $planted plants put in'}'
            '${plantedKnown > 0 ? ' · survival across checked cohorts: $aliveKnown of $plantedKnown alive (${(100 * aliveKnown / plantedKnown).toStringAsFixed(0)}%)' : ''}',
            style: const pw.TextStyle(fontSize: 10),
          ),
          pw.SizedBox(height: 8),

          // ---- Photos ----
          if (photoFiles.isNotEmpty) ...[
            label('Photographs'),
            pw.SizedBox(height: 4),
            pw.Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (date, f) in photoFiles)
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Image(
                        pw.MemoryImage(f.readAsBytesSync()),
                        width: 156,
                        height: 117,
                        fit: pw.BoxFit.cover,
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        date,
                        style: pw.TextStyle(fontSize: 7, color: _soft),
                      ),
                    ],
                  ),
              ],
            ),
            if (linkedPhotoCount > photoFiles.length)
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 4),
                child: pw.Text(
                  'Showing ${photoFiles.length} of $linkedPhotoCount '
                  'photographs on record; the full set travels with the '
                  'data export.',
                  style: pw.TextStyle(fontSize: 8, color: _soft),
                ),
              ),
          ],
        ],
      ),
    );
    return doc.save();
  }
}
