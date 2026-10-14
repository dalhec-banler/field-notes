part of '../capture_screen.dart';

mixin _CaptureShutterStep on _CaptureSave {
  // Step 0 — shutter.
  Widget _buildShutter() {
    final camera = _camera;
    final fix = _fix;
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_cameraError != null)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _cameraError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: Type.serif,
                          color: Color(0xB3F4ECD8),
                        ),
                      ),
                      SizedBox(height: 14),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Press.paperRaised,
                          side: BorderSide(
                            color: Press.paperRaised,
                            width: 1.5,
                          ),
                        ),
                        onPressed: () async {
                          if (_cameraPermanentlyDenied) {
                            await openAppSettings();
                          } else {
                            setState(() => _cameraError = null);
                            await _initCamera();
                          }
                        },
                        child: Text(
                          _cameraPermanentlyDenied
                              ? 'OPEN SETTINGS'
                              : 'GRANT CAMERA ACCESS',
                        ),
                      ),
                    ],
                  ),
                )
              else if (camera == null)
                Center(
                  child: CircularProgressIndicator(color: Press.paperRaised),
                )
              else
                CameraPreview(camera),
              // Scrim.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x421E2C25), Color(0x801E2C25)],
                  ),
                ),
              ),
              // Inset frame line.
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.all(22),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Color(0x66F4ECD8), width: 1.5),
                    ),
                  ),
                ),
              ),
              // Corner diamonds.
              Positioned(
                top: 30,
                left: 30,
                child: Diamond(size: 9, color: Press.sage),
              ),
              Positioned(
                top: 30,
                right: 30,
                child: Diamond(size: 9, color: Press.sage),
              ),
              // Focus square.
              Center(
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    border: Border.all(color: Color(0x99F4ECD8), width: 1.5),
                  ),
                ),
              ),
              // Top readout.
              Positioned(
                top: 34,
                left: 44,
                right: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    MonoLabel(
                      camera == null ? '◆ Starting camera…' : '◆ Tap to shoot',
                      size: 9.5,
                      spacing: 1.8,
                      color: Press.paperRaised,
                    ),
                    MonoLabel(
                      widget.isPlaced
                          ? 'Placed on the map'
                          : fix == null
                          ? 'GPS searching — save works anyway'
                          : 'GPS ±${fix.accuracy.toStringAsFixed(0)} m',
                      size: 9.5,
                      spacing: 1.4,
                      color: Press.paperRaised,
                    ),
                  ],
                ),
              ),
              // Bottom-left coordinates: the placed point if there is one,
              // else the live fix.
              if (widget.isPlaced || fix != null)
                Positioned(
                  left: 34,
                  bottom: 34,
                  child: MonoLabel(
                    widget.isPlaced
                        ? '${widget.placedLat!.toStringAsFixed(5)}\n${widget.placedLng!.toStringAsFixed(5)}'
                        : '${fix!.latitude.toStringAsFixed(5)}\n${fix.longitude.toStringAsFixed(5)}',
                    size: 9.5,
                    spacing: 1.2,
                    color: Press.paperRaised,
                    opacity: 0.9,
                  ),
                ),
            ],
          ),
        ),
        // Shutter bar: Cancel · shutter · No photo — which advances exactly
        // like the shutter does.
        Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              SizedBox(
                width: 112,
                height: 58,
                child: TextButton(
                  onPressed: _confirmDiscard,
                  child: Text(
                    'CANCEL',
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: TextStyle(color: Color(0x99F4ECD8)),
                  ),
                ),
              ),
              GestureDetector(
                onTap: _takePhoto,
                child: Container(
                  width: Metrics.shutterSize,
                  height: Metrics.shutterSize,
                  decoration: BoxDecoration(
                    color: Press.oxblood,
                    shape: BoxShape.circle,
                    border: Border.all(color: Press.paperRaised, width: 4),
                  ),
                ),
              ),
              SizedBox(
                width: 90,
                height: 58,
                child: TextButton(
                  onPressed: _noPhoto,
                  child: Text(
                    'NO PHOTO',
                    style: TextStyle(color: Color(0x99F4ECD8)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
