import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// The custom title strip's height. The drag zone and the traffic-light row
  /// are both sized to it — the Electron `trafficLightPosition` equivalent.
  static let stripHeight: CGFloat = 38

  override func awakeFromNib() {
    let flutterViewController = TitleBarDragViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Canvas-first default: a 1600×900 content area, clamped to the screen's
    // visible frame and centered. Resizing afterwards is unaffected.
    if let screen = self.screen ?? NSScreen.main {
      let visible = screen.visibleFrame
      let target = NSSize(
        width: min(1600, visible.width - 48),
        height: min(900, visible.height - 48)
      )
      self.setContentSize(target)
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    styleMask.insert(.fullSizeContentView)

    #if DEBUG
    // Dev loop: the CLI launches the app from whatever Space the terminal is
    // on, and the window can end up stranded on a Space the user is not
    // looking at. Let it follow onto the active Space when it becomes key.
    collectionBehavior.insert(.moveToActiveSpace)
    #endif

    super.awakeFromNib()
  }

  override func layoutIfNeeded() {
    super.layoutIfNeeded()
    centerTrafficLights()
  }

  /// AppKit parks the lamp row for a standard-height titlebar and re-lays it
  /// out on every resize, so re-center it from the layout hook. The shift is
  /// idempotent (delta settles to zero), so this never loops.
  private func centerTrafficLights() {
    guard let close = standardWindowButton(.closeButton),
          let holder = close.superview else { return }
    let midY = holder.convert(close.frame, to: nil).midY
    let delta = (frame.height - Self.stripHeight / 2) - midY
    if abs(delta) > 0.5 { holder.frame.origin.y += delta }
  }
}

/// Routes drags that start in the custom Dart title strip to the window so the
/// frameless chrome stays movable, while plain clicks fall through to Flutter.
final class TitleBarDragViewController: FlutterViewController {
  static let titleBarHeight: CGFloat = MainFlutterWindow.stripHeight

  private var pendingTitleBarMouseDown: NSEvent?
  private var titleBarDragInFlight = false

  private func isInTitleStrip(_ event: NSEvent) -> Bool {
    guard let contentView = view.window?.contentView else { return false }
    let point = contentView.convert(event.locationInWindow, from: nil)
    return point.y >= contentView.bounds.height - Self.titleBarHeight
  }

  override func mouseDown(with event: NSEvent) {
    guard isInTitleStrip(event), event.type == .leftMouseDown else {
      super.mouseDown(with: event)
      return
    }
    if event.clickCount == 2 {
      view.window?.zoom(nil)
      return
    }
    pendingTitleBarMouseDown = event
    titleBarDragInFlight = false
  }

  override func mouseDragged(with event: NSEvent) {
    if let down = pendingTitleBarMouseDown {
      pendingTitleBarMouseDown = nil
      titleBarDragInFlight = true
      view.window?.performDrag(with: down)
      return
    }
    if titleBarDragInFlight { return }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if let down = pendingTitleBarMouseDown {
      pendingTitleBarMouseDown = nil
      super.mouseDown(with: down)
      super.mouseUp(with: event)
      return
    }
    if titleBarDragInFlight {
      titleBarDragInFlight = false
      return
    }
    super.mouseUp(with: event)
  }
}
