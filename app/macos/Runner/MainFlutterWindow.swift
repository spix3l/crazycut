import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var resizeObserver: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Let Flutter own the visible chrome while retaining native window controls.
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    isMovableByWindowBackground = true
    backgroundColor = NSColor(calibratedWhite: 0.078, alpha: 1.0)
    isOpaque = true

    // Keep the traffic lights visible over the app's top chrome.
    standardWindowButton(.closeButton)?.isHidden = false
    standardWindowButton(.miniaturizeButton)?.isHidden = false
    standardWindowButton(.zoomButton)?.isHidden = false
    repositionTrafficLights()
    resizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification,
      object: self,
      queue: .main
    ) { [weak self] _ in
      self?.repositionTrafficLights()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private func repositionTrafficLights() {
    let y = frame.height - 28
    standardWindowButton(.closeButton)?.setFrameOrigin(NSPoint(x: 16, y: y))
    standardWindowButton(.miniaturizeButton)?.setFrameOrigin(NSPoint(x: 36, y: y))
    standardWindowButton(.zoomButton)?.setFrameOrigin(NSPoint(x: 56, y: y))
  }

  deinit {
    if let observer = resizeObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}
