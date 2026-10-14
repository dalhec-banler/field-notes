import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../db/database.dart';
import '../id/id_models.dart';
import '../id/identification_service.dart';
import '../geo/zone_assignment.dart';
import '../app_scope.dart';
import '../repo/repos.dart';
import '../services/capture_writer.dart';
import '../services/env_context.dart';
import '../services/voice_note.dart';
import '../theme/tokens.dart';
import '../widgets/edit_record_sheet.dart' show kObservationTypes;
import '../widgets/press.dart';
import '../widgets/nativity_chip.dart';
import '../widgets/species_field.dart';
import 'identify_sheet.dart';
import '../services/diag.dart';

part 'capture/core.dart';
part 'capture/save.dart';
part 'capture/shutter_step.dart';
part 'capture/form_step.dart';
part 'capture/notes_step.dart';

/// Result handed back to the shell for the save toast.
class CaptureResult {
  CaptureResult(this.observationId, this.elapsed);
  final String observationId;
  final Duration elapsed;
}

/// Capture (design README §3.8): the flow the whole app is built around.
/// Camera-dark full-screen modal; save is never blocked on GPS, network, or
/// identification; a record without a photograph is a legitimate record.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.db,
    required this.property,
    this.placedLat,
    this.placedLng,
  });

  final FieldNotesDb db;
  final Property property;

  /// Set when the record was dropped by long-pressing the map (spec §7.1):
  /// the location is the pressed point, not the phone's fix.
  final double? placedLat;
  final double? placedLng;

  bool get isPlaced => placedLat != null && placedLng != null;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

/// Split along its three steps (D-038 item 7): the state and actions live
/// in `capture/core.dart` and `capture/save.dart`; each step's build is
/// its own part. One object, five files.
class _CaptureScreenState extends State<CaptureScreen>
    with
        _CaptureCore,
        _CaptureSave,
        _CaptureShutterStep,
        _CaptureFormStep,
        _CaptureNotesStep {
  @override
  void initState() {
    super.initState();
    _countZones();
    _initCamera();
    _initLocation();
  }

  @override
  void dispose() {
    _camera?.dispose();
    _fixSub?.cancel();
    _notesController.dispose();
    _discardShotFile();
    // Orderly stop → dispose so a half-written recording is never left in
    // the cache; an unsaved one is discarded.
    if (!_voiceSaved) _voice.discard(_voicePath);
    _voice.shutdown(discardRecording: !_voiceSaved);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Android back: notes → form, form → confirm, shutter → confirm too
      // when a photo/species/notes exist (a re-shot photo lives at step 0;
      // it must not vanish silently — Austin's audit, 2026-09-03).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _saving) return;
        if (_step == 2) {
          setState(() => _step = 1);
        } else {
          _confirmDiscard();
        }
      },
      child: Scaffold(
        backgroundColor: Press.cameraDark,
        body: SafeArea(
          child: switch (_step) {
            0 => _buildShutter(),
            1 => _buildForm(),
            _ => _buildNotes(),
          },
        ),
      ),
    );
  }
}
