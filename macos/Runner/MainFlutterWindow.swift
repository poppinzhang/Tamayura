import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var platform: MacOSPlatform?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    minSize = NSSize(width: 640, height: 560)
    setContentSize(NSSize(width: 1180, height: 780))
    center()
    platform = MacOSPlatform(viewController: flutterViewController)
    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
