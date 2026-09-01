import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // The desk wants room (D-024): open at a working size, clamped to the
    // screen, and let the user resize from there.
    DispatchQueue.main.async {
      guard let screen = self.screen ?? NSScreen.main else { return }
      let visible = screen.visibleFrame
      let w = min(1360, visible.width - 40)
      let h = min(860, visible.height - 40)
      self.setContentSize(NSSize(width: w, height: h))
      self.center()
    }
    self.minSize = NSSize(width: 900, height: 600)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
