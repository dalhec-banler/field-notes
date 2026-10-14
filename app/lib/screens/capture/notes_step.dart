part of '../capture_screen.dart';

mixin _CaptureNotesStep on _CaptureSave {
  // Step 2 — notes.
  Widget _buildNotes() {
    return Container(
      color: Press.paper,
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(6, 10, 13, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Press.ink,
                  width: Metrics.borderStructural,
                ),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  height: 46,
                  child: TextButton(
                    onPressed: () => setState(() => _step = 1),
                    child: Text('‹ BACK'),
                  ),
                ),
                SizedBox(width: 6),
                MonoLabel('Notes', size: 10, spacing: 1.8),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(Metrics.gutter),
              children: [
                // Voice note: one big mic target, live transcript beneath.
                ListenableBuilder(
                  listenable: _voice,
                  builder: (context, _) {
                    final rec = _voice.recording;
                    final secs = _voice.elapsed.inSeconds;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 58,
                          child: rec
                              ? FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Press.oxblood,
                                  ),
                                  icon: const Icon(Icons.stop),
                                  label: Text(
                                    'STOP · ${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
                                  ),
                                  onPressed: _toggleVoice,
                                )
                              : OutlinedButton.icon(
                                  icon: const Icon(Icons.mic),
                                  label: Text(
                                    _voicePath == null
                                        ? 'RECORD A VOICE NOTE'
                                        : 'VOICE NOTE SAVED · RECORD AGAIN',
                                  ),
                                  onPressed: _toggleVoice,
                                ),
                        ),
                        if (rec) ...[
                          const SizedBox(height: 8),
                          MonoLabel(
                            _voice.speechAvailable
                                ? (_voice.transcript.isEmpty
                                      ? 'Listening…'
                                      : _voice.transcript)
                                : 'Recording · no speech recognition on this phone',
                            size: 10,
                            opacity: 0.8,
                          ),
                        ],
                        const SizedBox(height: 12),
                      ],
                    );
                  },
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 124),
                  child: TextField(
                    controller: _notesController,
                    autofocus: false,
                    textCapitalization: TextCapitalization.sentences,
                    minLines: 5,
                    maxLines: 12,
                    cursorColor: Press.oxblood,
                    style: TextStyle(
                      fontFamily: Type.serif,
                      fontSize: 16.5,
                      height: 1.6,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'What did you see?',
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(Metrics.gutter),
            child: SizedBox(
              height: 58,
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'WRITING…' : 'SAVE OBSERVATION'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
