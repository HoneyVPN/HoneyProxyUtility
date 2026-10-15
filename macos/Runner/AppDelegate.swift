import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func application(_ application: NSApplication, open urls: [URL]) {
    let remaining = urls.filter { url in
      guard url.scheme?.lowercased() == "honeyvpn" else { return true }
      MacImportLinks.shared.receive(url.absoluteString)
      return false
    }
    if !remaining.isEmpty { super.application(application, open: remaining) }
    if remaining.count != urls.count {
      application.activate(ignoringOtherApps: true)
      application.windows.compactMap({ $0 as? MainFlutterWindow }).first?.makeKeyAndOrderFront(nil)
    }
  }

  @IBAction func openPreferences(_ sender: Any?) { navigate("/settings") }
  @IBAction func importServer(_ sender: Any?) { navigate("/converter") }

  private func navigate(_ path: String) {
    guard let window = NSApplication.shared.windows.compactMap({ $0 as? MainFlutterWindow }).first else { return }
    window.makeKeyAndOrderFront(nil)
    window.navigateTo(path)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
