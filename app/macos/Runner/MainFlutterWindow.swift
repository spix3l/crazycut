import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Transparent titlebar over the app's dark chrome: no visible border or
    // separator. Content stays below the titlebar, so AppKit keeps the traffic
    // lights in the top strip and the top edge stays natively draggable.
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    // Match CcColors.panel so the strip the traffic lights sit in is
    // invisible against the app's own toolbar.
    backgroundColor = NSColor(
      srgbRed: CGFloat(29) / 255,
      green: CGFloat(31) / 255,
      blue: CGFloat(35) / 255,
      alpha: 1
    )
    isOpaque = true

    standardWindowButton(.closeButton)?.isHidden = false
    standardWindowButton(.miniaturizeButton)?.isHidden = false
    standardWindowButton(.zoomButton)?.isHidden = false

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
