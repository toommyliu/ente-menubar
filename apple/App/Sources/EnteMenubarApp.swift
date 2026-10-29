import AppCore
import AppKit
import SwiftUI

@main
struct EnteMenubarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private var model: AppModel?
  private var lockObserver: LockObserver?
  private var statusItemController: StatusItemController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if CommandLine.arguments.contains("--delete-local-session") {
      do {
        let store = SessionStore(
          service: "dev.entemenubar.EnteMenubar.local", protection: .userPresence)
        try store.delete()
        guard try !store.containsSession() else { exit(1) }
        print("Local Keychain session is absent")
        exit(0)
      } catch {
        print(error.localizedDescription)
        exit(1)
      }
    }
    let model = AppModel.live()
    self.model = model
    NSApp.setActivationPolicy(.accessory)
    lockObserver = LockObserver(model: model)
    statusItemController = StatusItemController(model: model)
    Task { await model.run() }
  }

  func applicationWillTerminate(_ notification: Notification) { statusItemController?.stop() }
}
