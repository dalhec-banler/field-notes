import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../map/basemap_manager.dart';

/// Offline maps management (spec §7.11): download/replace/remove the basemap.
class OfflineMapsScreen extends StatefulWidget {
  const OfflineMapsScreen({super.key});

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  final _manager = BasemapManager();
  final _urlController = TextEditingController();
  int? _installedBytes;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_refresh);
    _refresh();
  }

  Future<void> _refresh() async {
    final bytes = await _manager.installedBytes();
    if (mounted) setState(() => _installedBytes = bytes);
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
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'PMTiles', extensions: ['pmtiles']),
    ]);
    if (file == null) return;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'basemap'))
      ..createSync(recursive: true);
    final dest = File(p.join(dir.path, BasemapManager.fileName));
    await File(file.path).copy(dest.path);
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('BASEMAP INSTALLED')));
    }
  }

  String _fmtBytes(int b) => b > 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(b / 1024).toStringAsFixed(0)} KB';

  @override
  Widget build(BuildContext context) {
    final installed = _installedBytes != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Offline maps')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                installed ? Icons.check_circle : Icons.map_outlined,
                color: installed ? Colors.green.shade700 : null,
              ),
              title: Text(installed ? 'Basemap installed' : 'No basemap'),
              subtitle: Text(installed
                  ? _fmtBytes(_installedBytes!)
                  : 'The map works without one, but shows no background.'),
              trailing: installed
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove basemap',
                      onPressed: () async {
                        await _manager.remove();
                        _refresh();
                      },
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 24),
          Text('Download a basemap',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Paste a direct link to a .pmtiles file. Make one for any area '
            'with the pmtiles tool (pmtiles extract) and host it anywhere — '
            'Dropbox, S3, or a home server.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'https://…/area.pmtiles',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('IMPORT .PMTILES FILE'),
              onPressed: _manager.downloading ? null : _importFile,
            ),
          ),
          const SizedBox(height: 12),
          if (_manager.downloading)
            Column(
              children: [
                LinearProgressIndicator(value: _manager.progress),
                const SizedBox(height: 8),
                Text(
                    '${((_manager.progress ?? 0) * 100).toStringAsFixed(0)}% — '
                    'safe to leave this screen'),
              ],
            )
          else
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('Download'),
                onPressed: () {
                  final url = _urlController.text.trim();
                  if (url.isEmpty) return;
                  _manager.download(url);
                },
              ),
            ),
          if (_manager.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('Download failed: ${_manager.error}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
