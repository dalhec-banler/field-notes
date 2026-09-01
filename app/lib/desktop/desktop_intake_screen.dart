import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../backup/backup_engine.dart';
import '../backup/lan_receiver.dart';
import '../backup/restore.dart';
import '../backup/target.dart';
import '../db/database.dart';
import '../screens/drive_backup_screen.dart';
import '../screens/restore_screen.dart';
import '../services/app_prefs.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import 'receive_backup_panel.dart';
import 'relaunch.dart';

/// The desk's front door (D-024). Records are born on the field device; a
/// computer never starts a property from nothing. It brings the phone's
/// record over — across the LAN, from Google Drive, or from a backup file —
/// and then reopens on the copy.
class DesktopIntakeScreen extends StatefulWidget {
  DesktopIntakeScreen({super.key, required this.db, required this.prefs});

  final FieldNotesDb db;
  final AppPrefs prefs;

  @override
  State<DesktopIntakeScreen> createState() => _DesktopIntakeScreenState();
}

class _DesktopIntakeScreenState extends State<DesktopIntakeScreen> {
  final _secret = TextEditingController();
  bool _staged = false;
  bool _busy = false;
  String? _status;
  bool _hasReceivedStore = false;
  int _filesReceived = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final docs = await getApplicationDocumentsDirectory();
    final store = await receivedBackupsDir();
    final manifest = File('${store.path}/${BackupEngine.root}/manifest.json');
    if (!mounted) return;
    setState(() {
      _staged = RestorePipeline(docs).hasStagedRestore;
      _hasReceivedStore = manifest.existsSync();
    });
  }

  void _onReceiver(LanReceiver r) {
    _filesReceived = r.filesReceived;
    _refresh();
  }

  /// Open the copy the phone pushed: decrypt with the passphrase (or the
  /// 12 words), stage it, and offer the restart. Same pipeline as every
  /// other restore, same integrity refusal.
  Future<void> _openReceived() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Reading the copy…';
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final store = await receivedBackupsDir();
      final secret = _secret.text.trim();
      final summary = await RestorePipeline(docs).stageFromTarget(
        DirectoryTarget(store),
        secret: secret.isEmpty ? null : secret,
      );
      if (!mounted) return;
      setState(() => _status = summary);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '$e'.replaceFirst(RegExp(r'^\w*Error: '), ''));
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Press.paperEdge,
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: EdgeInsets.fromLTRB(32, 48, 32, 48),
            children: [
              Kicker('Field Notes on this computer'),
              SizedBox(height: 10),
              Text(
                'BRING THE\nRECORD OVER',
                style: TextStyle(
                  fontFamily: Type.slab,
                  fontWeight: FontWeight.w900,
                  fontSize: 44,
                  height: 0.95,
                  color: Press.ink,
                ),
              ),
              SizedBox(height: 14),
              Text(
                'Records are made in the field, on the phone. This desk is '
                'for going back over them — editing, refining, and exporting '
                'what you need for reports and partners. It starts from a '
                'copy of the phone\'s record, never from a blank page.',
                style: TextStyle(
                  fontFamily: Type.serif,
                  fontSize: 16.5,
                  height: 1.5,
                ),
              ),
              SizedBox(height: 26),
              if (_staged) _stagedCard(),
              ReceiveBackupPanel(
                padding: EdgeInsets.zero,
                onChanged: _onReceiver,
              ),
              if (_hasReceivedStore) _openCopyCard(),
              SizedBox(height: 14),
              _intakeCard(
                label: 'From Google Drive',
                body:
                    'If the phone backs up to Drive, sign in with the same '
                    'Google account and restore the copy here.',
                action: 'OPEN DRIVE',
                onTap: () => _push(
                  DriveBackupScreen(db: widget.db, prefs: widget.prefs),
                ),
              ),
              SizedBox(height: 14),
              _intakeCard(
                label: 'From a backup file',
                body:
                    'A zip from "Share backup" on the phone, or a copy you '
                    'kept anywhere.',
                action: 'CHOOSE FILE',
                onTap: () => _push(RestoreScreen()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _intakeCard({
    required String label,
    required String body,
    required String action,
    required VoidCallback onTap,
  }) {
    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Press.paperRaised,
        border: Border.all(color: Press.borderInk, width: 1.5),
      ),
      child: Row(
        children: [
          Diamond(size: 11, color: Press.inkSoft),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MonoLabel(label, size: 9, spacing: 1.8),
                SizedBox(height: 6),
                Text(
                  body,
                  style: TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 14),
          SizedBox(
            height: 40,
            child: OutlinedButton(onPressed: onTap, child: Text(action)),
          ),
        ],
      ),
    );
  }

  Widget _openCopyCard() {
    return Container(
      margin: EdgeInsets.only(top: 10),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Press.paper,
        border: Border.all(color: Press.borderInk, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MonoLabel(
            _filesReceived > 0
                ? 'A copy has arrived · $_filesReceived files this session'
                : 'A copy from the phone is on this computer',
            size: 9,
            spacing: 1.8,
            color: Press.sage,
          ),
          SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _secret,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Passphrase or 12-word recovery phrase',
                    helperText: 'Leave empty if the phone backs up unencrypted',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _openReceived(),
                ),
              ),
              SizedBox(width: 12),
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: _busy ? null : _openReceived,
                  child: Text(_busy ? 'WORKING…' : 'OPEN THE COPY'),
                ),
              ),
            ],
          ),
          if (_status != null) ...[
            SizedBox(height: 10),
            Text(
              _status!,
              style: TextStyle(fontFamily: Type.serif, fontSize: 14),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stagedCard() {
    return Container(
      margin: EdgeInsets.only(bottom: 14),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Press.paper,
        border: Border.all(color: Press.sage, width: 2),
      ),
      child: Row(
        children: [
          Diamond(size: 11, color: Press.sage, filled: true),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'The copy is ready. It applies when Field Notes reopens.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 15,
                height: 1.4,
              ),
            ),
          ),
          SizedBox(width: 14),
          SizedBox(
            height: 44,
            child: FilledButton(
              onPressed: relaunchApp,
              child: Text(canRelaunch ? 'QUIT & REOPEN' : 'QUIT'),
            ),
          ),
        ],
      ),
    );
  }
}
