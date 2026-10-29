import AppCore
import SwiftUI

@main
struct EnteMenubarApp: App {
  @State private var model: AppModel

  init() {
    let model = AppModel.live()
    _model = State(initialValue: model)
    Task { await model.run() }
  }

  var body: some Scene {
    MenuBarExtra("Ente Auth", systemImage: "lock.shield") {
      PopoverView(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}
