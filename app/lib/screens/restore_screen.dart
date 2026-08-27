import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../backup/restore.dart';

/// Restore from a backup zip (spec §11.9). The staged data applies on next
/// launch — DB first, so the app is usable the moment it reopens.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  final _secretController = TextEditingController();
  bool _busy = false;
  String? _status;
  XFile? _zip;

  @override
  void dispose() {
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _pickZip() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Backup zip', extensions: ['zip']),
    ]);
    if (file != null && mounted) setState(() => _zip = file);
  }

  Future<void> _restore() async {
    final zip = _zip;
    if (zip == null || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Reading backup…';
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final pipeline = RestorePipeline(docs);
      final secret = _secretController.text.trim();
      final summary = await pipeline.stageFromZip(File(zip.path),
          secret: secret.isEmpty ? null : secret);
      if (!mounted) return;
      setState(() => _status = summary);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _status = '$e'.replaceFirst(RegExp(r'^\w*Error: '), ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Restore from backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Pick a Field Notes backup zip (from "Share backup" on another '
            'phone, or a copy you kept). Your current data is set aside, not '
            'deleted.',
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.folder_zip_outlined),
              label: Text(_zip == null ? 'Choose backup zip' : _zip!.name),
              onPressed: _busy ? null : _pickZip,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _secretController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Passphrase or 12-word recovery phrase',
              helperText: 'Leave empty for an unencrypted backup',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              icon: const Icon(Icons.restore),
              label: Text(_busy ? 'Working…' : 'Restore'),
              onPressed: _busy || _zip == null ? null : _restore,
            ),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_status!,
                  style: Theme.of(context).textTheme.bodyLarge),
            ),
        ],
      ),
    );
  }
}
