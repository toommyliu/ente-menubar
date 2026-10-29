import AppKit
import SwiftUI
import Testing

@testable import AppCore

@Suite @MainActor
struct SignInViewTests {
  @Test func passwordReceivesFocusAfterEmailAndRejectedPassword() async throws {
    _ = NSApplication.shared
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let store = SessionStore(
      service: "dev.entemenubar.EnteMenubar.tests.\(UUID())", protection: .unprotectedForTests)
    let directory = FileManager.default.temporaryDirectory.appending(path: "EnteMenubar-tests-\(UUID())")
    defer {
      try? store.delete()
      try? FileManager.default.removeItem(at: directory)
    }
    let model = AppModel(
      config: AppModel.configuration(environment: [
        "ENTE_MENUBAR_API_ORIGIN": museum.fixture.endpoint
      ]), sessionStore: store, cacheStore: CacheStore(url: directory.appending(path: "cache.bin")))
    await model.launch()
    let host = NSHostingView(rootView: PopoverView(model: model))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 348, height: 400),
      styleMask: .titled, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.alphaValue = 0
    window.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    try #require(await eventually { textFields(in: host).contains { $0.isEditable } })
    let email = try #require(textFields(in: host).first { $0.isEditable })
    #expect(window.makeFirstResponder(email))
    #expect(focusedField(in: window) === email)
    model.setEmail(museum.fixture.email)
    await model.submit()
    try #require(await eventually { focusedField(in: window) is NSSecureTextField })
    await model.submit("wrong password")
    guard case .signedOut(let signIn) = model.phase else {
      Issue.record("Expected password retry")
      return
    }
    #expect(signIn.step == .password)
    #expect(signIn.error == "Incorrect password. Try again.")
    try #require(await eventually { focusedField(in: window) is NSSecureTextField })
  }

  private func focusedField(in window: NSWindow) -> NSTextField? {
    if let field = window.firstResponder as? NSTextField { return field }
    return window.contentView.flatMap { view in
      textFields(in: view).first { field in
        field.currentEditor() != nil && field.currentEditor() === window.firstResponder
      }
    }
  }

  private func textFields(in view: NSView) -> [NSTextField] {
    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
  }
}
