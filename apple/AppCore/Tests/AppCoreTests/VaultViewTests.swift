import AppKit
import SwiftUI
import Testing

@testable import AppCore

@Suite(.serialized) @MainActor
struct VaultViewTests {
  @Test func returnInSearchCopiesTheSelectedCode() async throws {
    _ = NSApplication.shared
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let directory = FileManager.default.temporaryDirectory.appending(path: "vault-view-\(UUID())")
    let store = SessionStore(service: "vault-view-\(UUID())", protection: .unprotectedForTests)
    let board = NSPasteboard(name: NSPasteboard.Name("vault-view-\(UUID())"))
    defer {
      try? store.delete()
      try? FileManager.default.removeItem(at: directory)
      board.releaseGlobally()
    }
    let model = AppModel(
      config: AppModel.configuration(environment: ["ENTE_MENUBAR_API_ORIGIN": museum.fixture.endpoint]),
      sessionStore: store, cacheStore: CacheStore(url: directory.appending(path: "cache.bin")),
      pasteboard: board, contextProvider: FakeContextProvider())
    await model.launch()
    model.setVisible(true)
    model.setEmail(museum.fixture.email)
    await model.submit(password: museum.fixture.password)
    try #require(model.filteredCodes.isEmpty == false)

    let host = NSHostingView(rootView: PopoverView(model: model))
    let window = VaultTestPanel(contentRect: NSRect(x: 0, y: 0, width: 348, height: 500),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    host.layoutSubtreeIfNeeded()
    try #require(await eventually { searchField(in: host) != nil })
    #expect(window.makeFirstResponder(try #require(searchField(in: host))))

    let first = model.selectedRowID
    model.moveSelection(1)
    let picked = try #require(model.selectedID)
    #expect(model.selectedRowID != first)
    let editor = try #require(window.firstResponder as? NSTextView)
    editor.insertNewline(nil)

    #expect(model.copiedID == picked)
    #expect(model.selectedID == picked)
  }

  private func searchField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap(searchField).first
  }
}

private final class VaultTestPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}
