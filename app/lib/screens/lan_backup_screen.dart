import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../backup/backup_service.dart';
import '../backup/lan_target.dart';
import '../db/database.dart';
import '../services/app_prefs.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Back up to your own computer, over your own network (D-019).
///
/// The strongest privacy option the app offers: the copy leaves the phone
/// and lands on a machine you own, without touching the internet or any
/// account. The phone still encrypts first — the computer only ever holds
/// opaque files.
class LanBackupScreen extends StatefulWidget {
  const LanBackupScreen({super.key, required this.db, required this.prefs});

  final FieldNotesDb db;
  final AppPrefs prefs;

  @override
  State<LanBackupScreen> createState() => _LanBackupScreenState();
}

class _LanBackupScreenState extends State<LanBackupScreen> {
  late final _service = BackupService(widget.db);
  final _hostController = TextEditingController();
  final _codeController = TextEditingController();
  bool _busy = false;
  String? _status;
  bool _paired = false;

  @override
  void initState() {
    super.initState();
    _hostController.text = widget.prefs.lanHost ?? '';
    _codeController.text = widget.prefs.lanCode ?? '';
    _paired = widget.prefs.lanHost != null;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  ({String host, int port})? _parseHost() {
    final raw = _hostController.text.trim();
    if (raw.isEmpty) return null;
    // Accept a pasted pairing link, or a bare host / host:port.
    final pairing = LanTarget.decodePairing(raw);
    if (pairing != null) {
      _codeController.text = pairing.token;
      return (host: pairing.host, port: pairing.port);
    }
    final parts = raw.split(':');
    return (
      host: parts.first,
      port: parts.length > 1
          ? int.tryParse(parts[1]) ?? LanTarget.defaultPort
          : LanTarget.defaultPort,
    );
  }

  LanTarget? _target() {
    final h = _parseHost();
    final code = _codeController.text.trim();
    if (h == null || code.isEmpty) return null;
    return LanTarget(host: h.host, port: h.port, token: code);
  }

  Future<void> _test() async {
    final target = _target();
    if (target == null) {
      setState(() => _status = 'Enter the address and code from the computer.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Looking for that computer…';
    });
    final ok = await target.ping();
    target.close();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _paired = ok;
      _status = ok
          ? 'Found it. This phone is paired.'
          : 'No answer. Check both are on the same Wi-Fi, the receiver is '
              'switched on, and the code matches.';
    });
    if (ok) {
      widget.prefs.lanHost = '${target.host}:${target.port}';
      widget.prefs.lanCode = target.token;
    }
  }

  Future<void> _backup() async {
    final target = _target();
    if (target == null) return;
    setState(() {
      _busy = true;
      _status = 'Backing up to ${target.host}…';
    });
    try {
      final engine = await _service.engineForTarget(
        target,
        askPassphrase: () => _askPassphrase(context),
        onStatus: (s) => setState(() => _status = s),
      );
      if (engine == null) {
        setState(() => _status = null);
        return;
      }
      final summary = await _service.backupNow(engine);
      if (mounted) setState(() => _status = summary);
    } catch (e) {
      if (mounted) setState(() => _status = 'Backup failed: $e');
    } finally {
      target.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPassphrase(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('BACKUP PASSPHRASE'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Passphrase'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('CONTINUE')),
        ],
      ),
    );
  }

  Widget _step(int n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 22, child: MonoLabel('$n.', size: 10, spacing: 1.2)),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontFamily: Type.serif, fontSize: 15, height: 1.4)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Back up to a computer')),
      body: ListView(
        padding: const EdgeInsets.all(Metrics.gutter),
        children: [
          const Text(
            'The copy goes from this phone to a computer you own, across your '
            'own network. It never touches the internet and there is no '
            'account. The phone encrypts first, so the computer only ever '
            'holds files it cannot read.',
            style: TextStyle(fontFamily: Type.serif, fontSize: 15.5, height: 1.45),
          ),
          const SizedBox(height: 18),
          const MonoLabel('On the computer', size: 9, spacing: 1.8),
          const SizedBox(height: 8),
          _step(1, 'Open Field Notes on the computer.'),
          _step(2, 'Go to Data → Receive a backup, and switch it on.'),
          _step(3, 'It shows an address and a six-digit code.'),
          const SizedBox(height: 18),
          const MonoLabel('On this phone', size: 9, spacing: 1.8),
          const SizedBox(height: 8),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Address (e.g. 192.168.1.42)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _codeController,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: 'Six-digit code', isDense: true),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.content_paste, size: 18),
            label: const Text('PASTE PAIRING LINK'),
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              final text = data?.text;
              if (text == null) return;
              setState(() => _hostController.text = text.trim());
              _parseHost();
              setState(() {});
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _busy ? null : _test,
                    child: const Text('TEST'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: _busy || !_paired ? null : _backup,
                    child: Text(_busy ? 'WORKING…' : 'BACK UP NOW'),
                  ),
                ),
              ),
            ],
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_status!,
                  style: const TextStyle(
                      fontFamily: Type.serif, fontSize: 15.5, height: 1.4)),
            ),
          const SizedBox(height: 20),
          const MonoLabel(
              'Both devices must be on the same network. The code changes '
              'each time the receiver is switched on.',
              size: 9,
              opacity: 0.7),
        ],
      ),
    );
  }
}
