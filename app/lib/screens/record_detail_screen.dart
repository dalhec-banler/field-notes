import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../db/database.dart';
import '../repo/repos.dart';
import '../theme/tokens.dart';
import '../widgets/photo_gallery.dart';
import '../widgets/press.dart';
import '../widgets/condition_log_dialog.dart';
import '../widgets/confirm.dart';
import '../widgets/edit_record_sheet.dart';
import '../widgets/edit_sheet.dart';
import '../widgets/nativity_chip.dart';
import '../widgets/removal_chip.dart';

import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../geo/zone_assignment.dart' show noZoneLabel;
import '../services/desk.dart';
import '../services/media_store.dart';
import '../services/review.dart';
import 'identify_sheet.dart';
import 'move_pin_screen.dart';
import '../protocols/indicators.dart';
import '../protocols/protocol_service.dart';
import 'monitoring/run_summary_card.dart';
import 'monitoring/site_detail_screen.dart';
import 'photo_points/photo_point_history_screen.dart';
import 'species_detail_sheet.dart';

part 'record_detail/core.dart';
part 'record_detail/edits.dart';
part 'record_detail/header.dart';
part 'record_detail/sections.dart';
part 'record_detail/actions.dart';

/// Record detail (design README §3.3): photo header, title block, fact card
/// keyed by the actual schema field names — the app and the schema stay
/// honest with each other.
class RecordDetailScreen extends StatefulWidget {
  const RecordDetailScreen({
    super.key,
    required this.db,
    required this.obsId,
    this.embedded = false,
  });

  final FieldNotesDb db;
  final String obsId;

  /// Living inside the desk's pane (D-024): no back chip, and the photo
  /// header fits the photo rather than cropping it to a phone plate.
  final bool embedded;

  @override
  State<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

/// Split along the page (D-038 item 7): state and loading in
/// `record_detail/core.dart`, the writes in `edits.dart`, and the page's
/// children in header / sections / actions. One object, six files.
class _RecordDetailScreenState extends State<RecordDetailScreen>
    with
        _RecordDetailCore,
        _RecordEdits,
        _RecordHeader,
        _RecordSections,
        _RecordActions {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _playerInstance?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final obs = _obs;
    if (obs == null) {
      return Scaffold(
        appBar: widget.embedded ? null : AppBar(),
        body: Center(
          child: _gone
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'This record is gone from the ledger — removed here or '
                    'on another device.',
                    textAlign: TextAlign.center,
                  ),
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    final typeColor = recordTypeColor(obs.observationType);
    // observed_at is stored UTC (spec §4); show it in the phone's local time
    // so the label (local_tz) and the digits agree.
    final parsed = DateTime.tryParse(obs.observedAt)?.toLocal();
    final when = parsed == null
        ? obs.observedAt
        : '${parsed.year.toString().padLeft(4, '0')}-'
              '${parsed.month.toString().padLeft(2, '0')}-'
              '${parsed.day.toString().padLeft(2, '0')} '
              '${parsed.hour.toString().padLeft(2, '0')}:'
              '${parsed.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      body: _withBack(
        ListView(
          padding: EdgeInsets.zero,
          children: [
            ..._headerChildren(obs, typeColor),
            ..._sectionChildren(obs, when),
            ..._actionChildren(obs),
          ],
        ),
      ),
    );
  }
}
