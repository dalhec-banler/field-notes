import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../map/area_downloader.dart';
import '../map/basemap_manager.dart';
import '../services/app_prefs.dart';
import '../services/network_policy.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Offline maps management (spec §7.11): what's on the phone, and the three
/// ways to get more — capture an area from the map, import a file, or
/// download from a link.
class OfflineMapsScreen extends StatefulWidget {
  const OfflineMapsScreen({super.key});

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  final _manager = BasemapManager();
  final _urlController = TextEditingController();
  int? _installedBytes;
  int? _capturedBytes;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_refresh);
    _refresh();
  }

  Future<void> _refresh() async {
    final bytes = await _manager.installedBytes();
    final captured = await AreaDownloader.target();
    final capturedBytes = captured.existsSync() ? captured.lengthSync() : null;
    if (mounted) {
      setState(() {
        _installedBytes = bytes;
        _capturedBytes = capturedBytes;
      });
    }
  }

  @override
  void dispose() {
    _manager.removeListener(_refresh);
    _urlController.dispose();
    super.dispose();
  }

  /// Copy a .pmtiles picked via the system file picker into the basemap
  /// slot — works on release builds and needs no cable or server.
  Future<void> _importFile() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: 'PMTiles', extensions: ['pmtiles']),
      ],
    );
    if (file == null) return;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'basemap'))
      ..createSync(recursive: true);
    final dest = File(p.join(dir.path, BasemapManager.fileName));
    await File(file.path).copy(dest.path);
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('BASEMAP INSTALLED')));
    }
  }

  Future<void> _removeCaptured() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('REMOVE CAPTURED AREAS?'),
        content: Text(
          'Every area you captured from the map goes. Your records stay. '
          'You can capture again any time you have signal.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('KEEP'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('REMOVE'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final f = await AreaDownloader.target();
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final s = File('${f.path}$suffix');
      if (s.existsSync()) s.deleteSync();
    }
    _refresh();
  }

  String _fmtBytes(int b) => b > 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(b / 1024).toStringAsFixed(0)} KB';

  Widget _card({
    required String title,
    required String detail,
    required bool present,
    VoidCallback? onRemove,
  }) {
    return Container(
      padding: EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: Press.paperRaised,
        border: Border.all(color: Press.borderInk, width: 1.5),
      ),
      child: Row(
        children: [
          Diamond(
            size: 12,
            color: present ? Press.sage : Press.inkSoft,
            filled: present,
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: Type.slab,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: Press.ink,
                  ),
                ),
                SizedBox(height: 3),
                MonoLabel(detail, size: 9, spacing: 1.2, opacity: 0.75),
              ],
            ),
          ),
          if (present && onRemove != null)
            IconButton(
              icon: Icon(Icons.delete_outline, color: Press.oxblood),
              tooltip: 'Remove',
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final installed = _installedBytes != null;
    final captured = _capturedBytes != null;
    return Scaffold(
      appBar: AppBar(title: Text('Offline maps')),
      body: ListView(
        padding: EdgeInsets.all(Metrics.gutter),
        children: [
          MonoLabel('On this phone', size: 9, spacing: 1.8),
          SizedBox(height: 8),
          _card(
            title: 'Captured areas',
            detail: captured
                ? '${_fmtBytes(_capturedBytes!)} · from ⌗ Capture area on the map'
                : 'none yet · frame a spot on the map and tap ⌗ Capture area',
            present: captured,
            onRemove: _removeCaptured,
          ),
          SizedBox(height: 8),
          _card(
            title: 'Regional basemap file',
            detail: installed
                ? '${_fmtBytes(_installedBytes!)} · covers the whole area it was made for'
                : 'none · optional — capture areas work on their own',
            present: installed,
            onRemove: () async {
              await _manager.remove();
              _refresh();
            },
          ),
          SizedBox(height: 10),
          Text(
            'Captured areas draw first; the regional file fills in around '
            'them. Both live only on this phone and never need signal to use.',
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 15,
              height: 1.45,
            ),
          ),
          SizedBox(height: 26),
          MonoLabel('Add a regional basemap file', size: 9, spacing: 1.8),
          const SizedBox(height: 8),
          Text(
            'Easiest: tap ⌗ Capture area on the map while you have signal. '
            'For a whole county in one go, import a .pmtiles file someone '
            'made for you, or paste a link to one.',
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 15,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 56,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('IMPORT A .PMTILES FILE'),
              onPressed: _manager.downloading ? null : _importFile,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'https://…/area.pmtiles',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          if (_manager.downloading)
            Column(
              children: [
                LinearProgressIndicator(value: _manager.progress),
                const SizedBox(height: 8),
                Text(
                  '${((_manager.progress ?? 0) * 100).toStringAsFixed(0)}% — '
                  'safe to leave this screen',
                ),
              ],
            )
          else
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('DOWNLOAD FROM LINK'),
                onPressed: () async {
                  final url = _urlController.text.trim();
                  if (url.isEmpty) return;
                  // D-016: a whole-county archive is hundreds of MB.
                  final prefs = await AppPrefs.load();
                  final verdict = await NetworkPolicy().bulkVerdict(prefs);
                  if (!context.mounted) return;
                  if (verdict == BulkVerdict.offline) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('NO SIGNAL — TRY AGAIN ON WI-FI'),
                      ),
                    );
                    return;
                  }
                  if (verdict == BulkVerdict.cellularBlocked) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'WAITING FOR WI-FI · allow cellular downloads in '
                          'Settings → Network to use mobile data',
                        ),
                      ),
                    );
                    return;
                  }
                  _manager.download(url);
                },
              ),
            ),
          if (_manager.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Download failed: ${_manager.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
