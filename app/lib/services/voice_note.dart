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

  /// Finalised recogniser sessions so far (Android dictation can end a
  /// session on a pause and start another; each returns its own words).
  final List<String> _segments = [];
  String _partial = '';

  /// Live transcript while recording; final after [stop].
  String get transcript =>
      [..._segments, if (_partial.isNotEmpty) _partial].join(' ').trim();

  String? _path;
  String? error;
  bool _speechReady = false;
  bool get speechAvailable => _speechReady;
  bool get listening => _speech.isListening;
  DateTime? _startedAt;
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  /// Length of the last finished recording (elapsed is zero once stopped).
  Duration lastDuration = Duration.zero;
  Timer? _tick;
  bool _disposed = false;

  Future<bool> start() async {
    if (_recording || _disposed) return _recording;
    error = null;
    _segments.clear();
    _partial = '';
    lastDuration = Duration.zero;
    try {
      if (!await _recorder.hasPermission()) {
        error = 'Microphone permission needed';
        _notify();
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
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => _notify());
      _notify();
    } catch (e) {
      error = 'Could not start recording: $e';
      _notify();
      return false;
    }

    // Transcription is best-effort and must never block the recording.
    try {
      _speechReady = await _speech.initialize(
        onError: (e) => debugPrint('[voice] speech error ${e.errorMsg}'),
        onStatus: (s) {
          // A session ended on its own (pause/limit): keep its words and
          // start another while the recording is still going.
          if (s == 'done' && _recording && !_disposed) {
            if (_partial.isNotEmpty) {
              _segments.add(_partial);
              _partial = '';
            }
            _listen();
          }
          _notify();
        },
      );
      if (_speechReady) await _listen();
    } catch (e) {
      debugPrint('[voice] speech unavailable: $e');
      _speechReady = false;
    }
    return true;
  }

  Future<void> _listen() async {
    if (!_recording || _disposed || _speech.isListening) return;
    try {
      await _speech.listen(
        onResult: (r) {
          _partial = r.recognizedWords;
          if (r.finalResult) {
            if (_partial.isNotEmpty) _segments.add(_partial);
            _partial = '';
          }
          _notify();
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(minutes: 3),
          pauseFor: const Duration(seconds: 10),
          cancelOnError: false,
        ),
      );
    } catch (e) {
      debugPrint('[voice] listen failed: $e');
    }
  }

  /// Stops both. Returns the audio file path (null if nothing was recorded).
  Future<String?> stop() async {
    if (!_recording) return null;
    _tick?.cancel();
    _tick = null;
    lastDuration = elapsed;
    try {
      if (_speech.isListening) await _speech.stop();
    } catch (_) {}
    if (_partial.isNotEmpty) {
      _segments.add(_partial);
      _partial = '';
    }
    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      error = 'Could not stop recording: $e';
    }
    _recording = false;
    _startedAt = null;
    _notify();
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

  /// Orderly teardown: finish any in-flight stop before the recorder goes
  /// away, so a half-written container is never left behind. Safe to call
  /// fire-and-forget from the owning screen's dispose.
  Future<void> shutdown({bool discardRecording = true}) async {
    if (_torndown) return;
    _torndown = true;
    _tick?.cancel();
    _tick = null;
    if (_recording) {
      final path = await stop();
      if (discardRecording) await discard(path);
    }
    try {
      await _speech.cancel();
    } catch (_) {}
    try {
      await _recorder.dispose();
    } catch (_) {}
  }

  bool _torndown = false;

  @override
  void dispose() {
    _disposed = true; // no more notifications from the async teardown
    shutdown();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
