import AppCore
import AppKit
import SwiftUI

@main
struct EnteMenubarApp: App {
  @State private var model: AppModel
  private let lockObserver: LockObserver

  init() {
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
    _model = State(initialValue: model)
    lockObserver = LockObserver(model: model)
    Task { await model.run() }
  }

  var body: some Scene {
    MenuBarExtra {
      PopoverView(model: model)
    } label: {
      Image(systemName: "lock.shield").accessibilityLabel("Ente Auth")
    }
    .menuBarExtraStyle(.window)
  }
}
