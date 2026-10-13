import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/desk.dart';
import '../services/diag.dart';
import '../theme/tokens.dart';
import '../widgets/confirm.dart';
import '../widgets/press.dart';

/// What the app caught and kept to itself (Settings → About → Diagnostics).
/// The ring, newest first, in the instrument voice; copy it, hand it over
/// as a file, or clear it. Nothing on this screen sends anything.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  String get _device => isDesk ? 'this computer' : 'this phone';

  Future<void> _copyAll() async {
    final entries = Diag.entries;
    await Clipboard.setData(ClipboardData(text: Diag.dump()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'COPIED · ${entries.length} ${entries.length == 1 ? 'ENTRY' : 'ENTRIES'}',
        ),
      ),
    );
  }

  /// One text file: the ring, then the on-disk log behind it. A phone
  /// opens the share sheet; a desk asks where to save.
  Future<void> _share() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final tmp = await getTemporaryDirectory();
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final name =
          'field-notes-diagnostics-${now.year}${two(now.month)}${two(now.day)}'
          '-${two(now.hour)}${two(now.minute)}.txt';
      final out = File(p.join(tmp.path, name));
      final b = StringBuffer()
        ..writeln('Field Notes diagnostics · ${now.toIso8601String()}')
        ..writeln('Kept on $_device. Newest first.')
        ..writeln()
        ..write(Diag.dump());
      for (final f in await Diag.logFiles()) {
        b
          ..writeln()
          ..writeln('---- ${p.basename(f.path)} ----')
          ..write(f.readAsStringSync());
      }
      out.writeAsStringSync(b.toString(), flush: true);
      final at = await deliverFile(out.path, text: 'Field Notes diagnostics');
      if (at != null && isDesk) {
        messenger.showSnackBar(SnackBar(content: Text('SAVED $at')));
      }
    } catch (e, st) {
      Diag.report(e, st, where: 'DiagnosticsScreen._share');
      messenger.showSnackBar(
        SnackBar(content: Text('COULD NOT WRITE THE FILE · TRY COPY ALL')),
      );
    }
  }

  Future<void> _clear() async {
    final sure = await confirmDialog(
      context,
      title: 'CLEAR DIAGNOSTICS?',
      body:
          'These notes go. Nothing else does — your records and settings '
          'are not touched.',
      confirmLabel: 'CLEAR',
    );
    if (!sure) return;
    await Diag.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final entries = Diag.entries;
    return Scaffold(
      appBar: AppBar(title: Text('Diagnostics')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              Metrics.gutter,
              Metrics.gutter,
              Metrics.gutter,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'When something goes wrong and the app carries on anyway, '
                  'a note lands here. It stays on $_device unless you '
                  'copy or share it yourself.',
                  style: TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
                SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: entries.isEmpty ? null : _copyAll,
                        child: Text('COPY ALL'),
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _share,
                        child: Text(isDesk ? 'SAVE' : 'SHARE'),
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: entries.isEmpty ? null : _clear,
                        child: Text('CLEAR'),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                MonoLabel(
                  entries.isEmpty
                      ? 'Nothing noted'
                      : '${entries.length} '
                            '${entries.length == 1 ? 'entry' : 'entries'} '
                            '· newest first · last ${Diag.ringCap} kept',
                  size: 9,
                  spacing: 1.8,
                ),
                SizedBox(height: 6),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Padding(
                    padding: EdgeInsets.all(Metrics.gutter),
                    child: Text(
                      'Nothing has gone wrong that the app noticed.',
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 15,
                        height: 1.45,
                        color: Press.inkSoft,
                      ),
                    ),
                  )
                : Container(
                    margin: EdgeInsets.fromLTRB(
                      Metrics.gutter,
                      0,
                      Metrics.gutter,
                      Metrics.gutter,
                    ),
                    decoration: BoxDecoration(
                      color: Press.paperRaised,
                      border: Border.all(
                        color: Press.borderInk,
                        width: Metrics.borderCard,
                      ),
                    ),
                    child: ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, i) =>
                          _EntryRow(entries[i], last: i == entries.length - 1),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow(this.entry, {required this.last});
  final DiagEntry entry;
  final bool last;

  static String _stamp(DateTime utc) {
    final t = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: Press.divider, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MonoLabel(_stamp(entry.at), size: 9, spacing: 1.2, opacity: 0.65),
              SizedBox(width: 10),
              Expanded(
                child: MonoLabel(
                  entry.where ?? '—',
                  size: 9,
                  spacing: 1.2,
                  color: entry.frames == null ? Press.inkSoft : Press.oxblood,
                  maxLines: 1,
                ),
              ),
            ],
          ),
          SizedBox(height: 4),
          SelectableText(
            entry.message,
            style: TextStyle(
              fontFamily: Type.mono,
              fontSize: 11.5,
              height: 1.45,
              color: Press.ink,
            ),
          ),
          if (entry.frames != null) ...[
            SizedBox(height: 3),
            Text(
              entry.frames!,
              style: TextStyle(
                fontFamily: Type.mono,
                fontSize: 9.5,
                height: 1.4,
                color: Press.inkSoft.withValues(alpha: 0.75),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
