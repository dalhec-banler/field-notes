import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../backup/lan_receiver.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Where a phone's LAN pushes land on this computer. The layout under it is
/// the backup store itself (`fieldnotes/…`), so a restore can read it as a
/// plain directory target with no repackaging.
Future<Directory> receivedBackupsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory(p.join(docs.path, 'received_backups'))
    ..createSync(recursive: true);
}

/// The desk half of LAN backup: switch it on, read the address and code to
/// the phone, watch files land. The computer never decrypts anything here.
class ReceiveBackupPanel extends StatefulWidget {
  ReceiveBackupPanel({super.key, this.onChanged, this.padding});

  /// Fires on every receiver state change (start, stop, each file landed).
  final ValueChanged<LanReceiver>? onChanged;
  final EdgeInsets? padding;

  @override
  State<ReceiveBackupPanel> createState() => _ReceiveBackupPanelState();
}

class _ReceiveBackupPanelState extends State<ReceiveBackupPanel> {
  LanReceiver? _receiver;
  bool _starting = false;

  @override
  void dispose() {
    _receiver?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_receiver?.running ?? false) {
      await _receiver!.stop();
      setState(() {});
      widget.onChanged?.call(_receiver!);
      return;
    }
    setState(() => _starting = true);
    final dir = await receivedBackupsDir();
    final r = _receiver ??= LanReceiver(storeDir: dir)
      ..addListener(() {
        if (!mounted) return;
        setState(() {});
        widget.onChanged?.call(_receiver!);
      });
    await r.start();
    if (mounted) setState(() => _starting = false);
    widget.onChanged?.call(r);
  }

  @override
  Widget build(BuildContext context) {
    final r = _receiver;
    final running = r?.running ?? false;
    return Padding(
      padding: widget.padding ?? EdgeInsets.fromLTRB(18, 18, 18, 0),
      child: Container(
        padding: EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Press.paperRaised,
          border: Border.all(
            color: running ? Press.sage : Press.borderInk,
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Diamond(
                  size: 11,
                  color: running ? Press.sage : Press.inkSoft,
                  filled: running,
                ),
                SizedBox(width: 8),
                MonoLabel('Pair with your phone', size: 9, spacing: 1.8),
                Spacer(),
                SizedBox(
                  height: 40,
                  child: OutlinedButton(
                    onPressed: _starting ? null : _toggle,
                    child: Text(running ? 'STOP' : 'SWITCH ON'),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10),
            Text(
              'Switch on, scan the code with the phone, and the phone sends '
              'its record here over your own network. Nothing goes to the '
              'internet, and this computer only ever holds encrypted files '
              'until you open the copy with your passphrase.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            if (running) ...[
              SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The QR carries the whole pairing link; the readouts
                  // beside it are for typing when a camera isn't handy.
                  if (r!.pairingString != null)
                    Container(
                      padding: EdgeInsets.all(6),
                      color: Colors.white,
                      child: QrImageView(
                        data: r.pairingString!,
                        size: 168,
                        backgroundColor: Colors.white,
                        eyeStyle: QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Color(0xFF1B1813),
                        ),
                        dataModuleStyle: QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Color(0xFF1B1813),
                        ),
                      ),
                    ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _readout(
                          'Address',
                          '${r.address ?? "unknown"}:${r.port}',
                        ),
                        SizedBox(height: 10),
                        _readout('Code', r.pairingCode ?? '—'),
                        SizedBox(height: 10),
                        _readout('Files received', '${r.filesReceived}'),
                        SizedBox(height: 10),
                        MonoLabel(
                          'On the phone: Settings → Pair with a computer → '
                          'SCAN THE QR CODE',
                          size: 9,
                          opacity: 0.7,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            if (r?.error != null) ...[
              SizedBox(height: 10),
              Text(
                r!.error!,
                style: TextStyle(
                  fontFamily: Type.serif,
                  fontSize: 14,
                  color: Press.oxblood,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _readout(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      MonoLabel(label, size: 8.5, opacity: 0.65),
      SizedBox(height: 3),
      Text(
        value,
        style: TextStyle(fontFamily: Type.mono, fontSize: 16, color: Press.ink),
      ),
    ],
  );
}
