import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../backup/lan_target.dart';
import '../theme/tokens.dart';

/// Point the phone at the computer's QR code. Returns the pairing link the
/// code carries (`fieldnotes://backup?…`), or null if dismissed. Anything
/// that isn't one of ours is ignored rather than trusted.
class ScanPairingScreen extends StatefulWidget {
  const ScanPairingScreen({super.key});

  @override
  State<ScanPairingScreen> createState() => _ScanPairingScreenState();
}

class _ScanPairingScreenState extends State<ScanPairingScreen> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || LanTarget.decodePairing(raw) == null) continue;
      _done = true;
      Navigator.of(context).pop(raw);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan the computer\'s code'),
      ),
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: EdgeInsets.all(Metrics.gutter),
              padding: EdgeInsets.all(14),
              color: Press.paper,
              child: Text(
                'On the computer: Pair with your phone → SWITCH ON. '
                'Hold the QR code in the frame.',
                style: TextStyle(fontFamily: Type.serif, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
