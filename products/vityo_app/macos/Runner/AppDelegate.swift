import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    #if DEBUG
    // Dev loop: `flutter run` spawns the binary directly, so LaunchServices
    // never foregrounds it ("Failed to foreground app; open returned 1").
    NSApp.activate(ignoringOtherApps: true)
    #endif
  }
}
