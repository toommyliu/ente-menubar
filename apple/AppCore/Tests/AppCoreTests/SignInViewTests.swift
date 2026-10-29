import AppKit
import SwiftUI
import Testing

@testable import AppCore

@Suite(.serialized) @MainActor
struct SignInViewTests {
  @Test(arguments: [false, true])
  func credentialsSubmitTogetherAndRetryWithoutLosingEmail(emailMFA: Bool) async throws {
    _ = NSApplication.shared
    let museum = try LocalMuseum(emailMFA: emailMFA)
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
    try #require(await eventually { textFields(in: host).filter { $0.isEditable }.count == 2 })
    let email = try #require(textFields(in: host).first { $0.isEditable && !($0 is NSSecureTextField) })
    let password = try #require(textFields(in: host).first { $0 is NSSecureTextField })
    #expect(email.contentType == nil)
    #expect(password.contentType == nil)
    #expect(window.makeFirstResponder(email))
    for _ in 0..<2 {
      try enter("", in: window)
      try #require(await eventually { focusedField(in: window) === password })
      try enter("", in: window)
      try #require(await eventually { focusedField(in: window) === email })
    }
    try enter("  " + museum.fixture.email.uppercased() + "  ", in: window)
    try #require(await eventually { focusedField(in: window) === password })
    try enter("wrong password", in: window)
    if emailMFA {
      try #require(await eventually { isEmailCode(model) })
      try #require(await eventually { focusedField(in: window)?.contentType == .oneTimeCode })
      try enter("000000", in: window)
      try #require(await eventually {
        if case .signedOut(let signIn) = model.phase { return !signIn.busy && signIn.error != nil }
        return false
      })
      #expect(isEmailCode(model))
      await model.resendCode()
      try #require(await eventually { focusedField(in: window)?.contentType == .oneTimeCode })
      try enter("123456", in: window)
    }
    try #require(await eventually(within: .seconds(15)) {
      if case .signedOut(let signIn) = model.phase {
        return !signIn.busy && signIn.step == .credentials
          && signIn.error == "Incorrect password. Try again."
      }
      return false
    })
    guard case .signedOut(let signIn) = model.phase else { return }
    #expect(signIn.error == "Incorrect password. Try again.")
    #expect(signIn.email == museum.fixture.email)
    #expect(try store.load() == nil)
    try #require(await eventually { focusedField(in: window) is NSSecureTextField })
    try enter(museum.fixture.password, in: window)
    if emailMFA {
      try #require(await eventually { isEmailCode(model) })
      try #require(await eventually { focusedField(in: window)?.contentType == .oneTimeCode })
      try enter("123456", in: window)
    }
    try #require(await eventually(within: .seconds(15)) {
      if case .ready = model.phase { return true }
      return false
    })
    #expect(try store.load()?.isEmpty == false)
    #expect(await eventually { model.filteredCodes.contains { $0.issuer == "RFC" } })
    await model.signOut()
    try #require(await eventually {
      textFields(in: host).filter { $0.isEditable }.count == 2
        && textFields(in: host).first { $0 is NSSecureTextField }?.stringValue == ""
    })
  }

  private func enter(_ value: String, in window: NSWindow) throws {
    let editor = try #require(window.firstResponder as? NSTextView)
    editor.selectAll(nil)
    editor.insertText(value, replacementRange: editor.selectedRange())
    editor.insertNewline(nil)
  }

  private func isEmailCode(_ model: AppModel) -> Bool {
    if case .signedOut(let signIn) = model.phase { return signIn.step == .emailCode && !signIn.busy }
    return false
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
