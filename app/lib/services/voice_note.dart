import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Voice note (spec §3.5, §7.2): record audio AND transcribe at the same
/// time. The audio file is the record; the transcript is a convenience that
/// lands in the notes field. Offline on Android when the language pack is
/// present; if speech recognition is unavailable the recording still works.
class VoiceNoteRecorder extends ChangeNotifier {
  final _recorder = AudioRecorder();
  final _speech = SpeechToText();

  bool _recording = false;
  bool get recording => _recording;

  String _transcript = '';
  /// Live transcript while recording; final after [stop].
  String get transcript => _transcript;

  String? _path;
  String? error;
  bool _speechReady = false;
  bool get speechAvailable => _speechReady;
  DateTime? _startedAt;
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);
  Timer? _tick;

  Future<bool> start() async {
    if (_recording) return true;
    error = null;
    _transcript = '';
    try {
      if (!await _recorder.hasPermission()) {
        error = 'Microphone permission needed';
        notifyListeners();
        return false;
      }
      final tmp = await getTemporaryDirectory();
      _path = p.join(tmp.path,
          'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: _path!,
      );
      _recording = true;
      _startedAt = DateTime.now();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
      notifyListeners();
    } catch (e) {
      error = 'Could not start recording: $e';
      notifyListeners();
      return false;
    }

    // Transcription is best-effort and must never block the recording.
    try {
      _speechReady = await _speech.initialize(
        onError: (e) => debugPrint('[voice] speech error ${e.errorMsg}'),
      );
      if (_speechReady) {
        await _speech.listen(
          onResult: (r) {
            _transcript = r.recognizedWords;
            notifyListeners();
          },
          listenOptions: SpeechListenOptions(
            partialResults: true,
            listenMode: ListenMode.dictation,
            listenFor: const Duration(minutes: 3),
            pauseFor: const Duration(seconds: 10),
            cancelOnError: false,
          ),
        );
      }
    } catch (e) {
      debugPrint('[voice] speech unavailable: $e');
      _speechReady = false;
    }
    return true;
  }

  /// Stops both. Returns the audio file path (null if nothing was recorded).
  Future<String?> stop() async {
    if (!_recording) return null;
    _tick?.cancel();
    _tick = null;
    try {
      if (_speech.isListening) await _speech.stop();
    } catch (_) {}
    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      error = 'Could not stop recording: $e';
    }
    _recording = false;
    _startedAt = null;
    notifyListeners();
    if (path != null && File(path).existsSync() && File(path).lengthSync() > 0) {
      return path;
    }
    return null;
  }

  /// Drop an unsaved recording.
  Future<void> discard(String? path) async {
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (_recording) {
      _recorder.stop().then((path) => discard(path)).catchError((_) => null);
    }
    _recorder.dispose();
    try {
      _speech.cancel();
    } catch (_) {}
    super.dispose();
  }
}
