import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import AppCore

private let k = KeyCode(kVK_ANSI_K), y = KeyCode(kVK_ANSI_Y), j = KeyCode(kVK_ANSI_J), n = KeyCode(kVK_ANSI_N)
@MainActor private let us = KeyLayout(characters: [.e: "e", .r: "r", .l: "l", .c: "c", .q: "q", k: "k", y: "y", j: "j"])
@MainActor private let dvorak = KeyLayout(characters: [.e: ".", .r: "p", .l: "n"])
private let open = KeyCombo(.e, [.option, .command])
private let sync = KeyCombo(.r, .command)
private let lock = KeyCombo(.l, .command)

private struct Refused: Error {}

@MainActor private final class FakeHotKeys {
  var calls: [KeyCombo?] = []
  var refused: Set<KeyCombo> = []
  var registered: KeyCombo?

  func register(_ combo: KeyCombo?) throws {
    if combo == registered { return }
    calls.append(combo)
    registered = nil
    if let combo, refused.contains(combo) { throw Refused() }
    registered = combo
  }
}

@Suite @MainActor final class ShortcutTests {
  let suite: String
  let preferences: UserDefaults
  let root: URL

  init() throws {
    let name = "shortcuts-\(UUID())"
    suite = name
    preferences = try #require(UserDefaults(suiteName: name))
    root = FileManager.default.temporaryDirectory.appending(path: name)
  }

  deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

  private func model(_ profile: String = "one", _ hotKeys: FakeHotKeys? = nil) -> AppModel {
    let model = AppModel(cacheStore: CacheStore(url: root.appending(path: "\(profile)/cache.bin")),
      contextProvider: FakeContextProvider(), preferences: preferences, loginItem: TestLoginItem())
    if let hotKeys { model.configureGlobalShortcut(hotKeys.register) }
    return model
  }

  private var preferenceKey: String { "shortcuts.\(root.appending(path: "one").path)" }

  @Test func defaultShortcutsMatchTodaysKeys() {
    let keymap = Keymap()
    #expect(ShortcutAction.allCases.map { keymap.combo(for: $0)?.label(in: us) } == ["⌥⌘E", "⌘↩", "⌘R", "⌘L"])
    #expect(keymap.isDefault == true)
    #expect(keymap.action(for: sync) == .syncNow)
    #expect(keymap.action(for: KeyCombo(.c, .command)) == nil)
  }

  @Test func labelsFollowTheLayoutAndAppleModifierOrder() {
    #expect(KeyCombo(.r, [.command, .shift, .option, .control]).label(in: us) == "⌃⌥⇧⌘R")
    #expect(sync.label(in: dvorak) == "⌘P")
    #expect(KeyCombo(.escape, .control).label(in: us) == "⌃⎋")
    #expect(KeyCombo(KeyCode(kVK_Space), .option).label(in: us) == "⌥Space")
    #expect(KeyCombo(KeyCode(kVK_F5), .command).label(in: us) == "⌘F5")
  }

  @Test func keyEventsKeepOnlyShortcutModifiers() throws {
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock, .function, .numericPad],
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: UInt16(kVK_UpArrow)))
    #expect(KeyCombo(event: event) == KeyCombo(KeyCode(kVK_UpArrow), .command))
  }

  @Test func menuItemsDrawTheBoundShortcut() {
    let item = NSMenuItem()
    item.setShortcut(KeyCombo(.return, .command), in: us)
    #expect(item.keyEquivalent == "\r")
    #expect(item.keyEquivalentModifierMask == [.command])
    item.setShortcut(open, in: dvorak)
    #expect(item.keyEquivalent == ".")
    #expect(item.keyEquivalentModifierMask == [.option, .command])
    item.setShortcut(nil, in: us)
    #expect(item.keyEquivalent == "")
    #expect(item.keyEquivalentModifierMask == [])
  }

  @Test func problemMessagesNameTheKeysAndTheOwner() {
    #expect(ShortcutProblem.needsModifier.message(in: us) == "Shortcuts need ⌘, ⌥, or ⌃.")
    #expect(ShortcutProblem.reserved(KeyCombo(.c, .command)).message(in: us) == "⌘C copies text in search.")
    #expect(ShortcutProblem.reserved(KeyCombo(.q, .command)).message(in: us) == "⌘Q quits Ente Auth.")
    #expect(ShortcutProblem.taken(lock, by: .lock).message(in: us) == "⌘L is already used by Lock.")
    #expect(ShortcutProblem.unavailable(KeyCombo(k, [.control, .option])).message(in: us)
      == "Couldn't register ⌃⌥K. Try a different shortcut.")
  }


  @Test func reservedCommandsFollowTheCommandLayout() {
    let azerty = KeyLayout(characters: [.q: "a", .a: "q"])
    var keymap = Keymap()
    #expect(throws: ShortcutProblem.reserved(KeyCombo(.q, .command))) {
      try keymap.assign(KeyCombo(.q, .command), to: .lock, in: azerty)
    }
    #expect(ShortcutProblem.reserved(KeyCombo(.q, .command)).message(in: azerty) == "⌘A selects all text in search.")
    #expect(throws: ShortcutProblem.reserved(KeyCombo(.a, .command))) {
      try keymap.assign(KeyCombo(.a, .command), to: .lock, in: azerty)
    }
    #expect(ShortcutProblem.reserved(KeyCombo(.a, .command)).message(in: azerty) == "⌘Q quits Ente Auth.")
    let commandLayout = KeyLayout { key, command in key == .r ? (command ? "c" : "p") : nil }
    #expect(throws: ShortcutProblem.reserved(sync)) {
      try keymap.assign(sync, to: .syncNow, in: commandLayout)
    }
  }

  @Test func storedOverridesKeepIntentAndDropInvalidEntries() throws {
    #expect(Keymap(stored: nil) == nil)
    #expect(Keymap(stored: Data("not json".utf8)) == nil)
    var stolen = try #require(Keymap(stored: Data(#"{"lock":{"key":15,"modifiers":8}}"#.utf8)))
    #expect(stolen.combo(for: .lock) == sync)
    #expect(stolen.combo(for: .syncNow) == nil)
    try stolen.assign(KeyCombo(k, .command), to: .copyNextCode, in: us)
    let json = try #require(JSONSerialization.jsonObject(with: stolen.stored) as? [String: Any])
    #expect(Set(json.keys) == ["lock", "copyNextCode"])
    #expect(Keymap(stored: stolen.stored) == stolen)
    let decoded = try #require(Keymap(stored: Data(#"{"unknown":null,"openEnteAuth":null,"copyNextCode":{"key":40,"modifiers":0},"syncNow":{"key":16,"modifiers":8},"lock":{"key":16,"modifiers":8}}"#.utf8)))
    #expect(decoded.combo(for: .openEnteAuth) == nil)
    #expect(decoded.combo(for: .copyNextCode) == KeyCombo(.return, .command))
    #expect(decoded.combo(for: .syncNow) == KeyCombo(y, .command))
    #expect(decoded.combo(for: .lock) == lock)
  }

  @Test func assignmentsRejectConflictsAndOwnDefaultRemovesOverride() throws {
    var keymap = Keymap()
    #expect(throws: ShortcutProblem.needsModifier) { try keymap.assign(KeyCombo(k, .shift), to: .lock, in: us) }
    #expect(throws: ShortcutProblem.taken(sync, by: .syncNow)) { try keymap.assign(sync, to: .lock, in: us) }
    try keymap.assign(KeyCombo(k, .command), to: .lock, in: us)
    #expect(keymap.action(for: KeyCombo(k, .command)) == .lock)
    #expect(keymap.action(for: lock) == nil)
    try keymap.assign(lock, to: .lock, in: us)
    #expect(keymap.isDefault == true)
    #expect(String(decoding: keymap.stored, as: UTF8.self) == "{}")
    keymap.clear(.openEnteAuth)
    #expect(String(decoding: keymap.stored, as: UTF8.self) == #"{"openEnteAuth":null}"#)
  }

  @Test func recordingReplacesAShortcutAndPersistsPerProfile() {
    let m = model()
    m.showShortcuts()
    m.setRecording(.syncNow)
    #expect(m.handleKeyPress(KeyCombo(y, .command)) == true)
    #expect(m.shortcutEditor == .browsing)
    #expect(m.keymap.combo(for: .syncNow) == KeyCombo(y, .command))
    m.closeShortcuts()
    #expect(m.handleKeyPress(sync) == false)
    #expect(m.handleKeyPress(KeyCombo(y, .command)) == true)
    #expect(model().keymap.combo(for: .syncNow) == KeyCombo(y, .command))
    #expect(model("two").keymap.combo(for: .syncNow) == sync)
  }

  @Test func rejectedCombosExplainWhyAndKeepRecording() {
    let m = model()
    m.showShortcuts()
    m.setRecording(.syncNow)
    #expect(m.handleKeyPress(KeyCombo(k, [])) == true)
    #expect(m.shortcutEditor == .recording(.syncNow, problem: .needsModifier))
    if case .recording(_, let problem) = m.shortcutEditor {
      #expect(problem?.message(in: us) == "Shortcuts need ⌘, ⌥, or ⌃.")
    }
    #expect(m.handleKeyPress(lock) == true)
    #expect(m.shortcutEditor == .recording(.syncNow, problem: .taken(lock, by: .lock)))
    if case .recording(_, let problem) = m.shortcutEditor {
      #expect(problem?.message(in: us) == "⌘L is already used by Lock.")
    }
    #expect(m.keymap.isDefault == true)
    #expect(preferences.data(forKey: preferenceKey) == nil)
  }

  @Test func escapeCancelsThenClosesAndTabCancelsWithoutConsumption() {
    let m = model()
    m.showShortcuts()
    m.setRecording(.lock)
    #expect(m.handleKeyPress(.escape) == true)
    #expect(m.shortcutEditor == .browsing)
    #expect(m.handleKeyPress(sync) == false)
    #expect(m.handleKeyPress(.escape) == true)
    #expect(m.shortcutEditor == nil)
    m.showShortcuts()
    m.setRecording(.syncNow)
    #expect(m.handleKeyPress(.tab) == false)
    #expect(m.shortcutEditor == .browsing)
    #expect(m.keymap.isDefault == true)
  }

  @Test func recordingSuspendsTheGlobalShortcutUntilItEnds() {
    let hotKeys = FakeHotKeys()
    let m = model("one", hotKeys)
    m.setVisible(true)
    m.showShortcuts()
    m.setRecording(.lock)
    _ = m.handleKeyPress(KeyCombo(k, .command))
    m.setRecording(.syncNow)
    m.setVisible(false)
    #expect(hotKeys.calls == [open, nil, open, nil, open])
    #expect(hotKeys.registered == open)
    #expect(m.shortcutEditor == nil)
  }

  @Test func refusedGlobalCandidateKeepsTheOldCombo() {
    let candidate = KeyCombo(k, [.control, .option])
    let hotKeys = FakeHotKeys()
    hotKeys.refused = [candidate]
    let m = model("one", hotKeys)
    m.showShortcuts()
    m.setRecording(.openEnteAuth)
    #expect(m.handleKeyPress(candidate) == true)
    #expect(m.shortcutEditor == .recording(.openEnteAuth, problem: .unavailable(candidate)))
    #expect(m.keymap.combo(for: .openEnteAuth) == open)
    #expect(preferences.data(forKey: preferenceKey) == nil)
    #expect(hotKeys.registered == nil)
    #expect(m.handleKeyPress(.escape) == true)
    #expect(hotKeys.registered == open)
    m.setRecording(.openEnteAuth)
    #expect(m.handleKeyPress(KeyCombo(j, [.control, .option])) == true)
    #expect(m.shortcutEditor == .browsing)
    #expect(model().keymap.combo(for: .openEnteAuth) == KeyCombo(j, [.control, .option]))
    #expect(hotKeys.calls == [open, nil, candidate, open, nil, KeyCombo(j, [.control, .option])])
    #expect(m.unavailableGlobalShortcut == nil)
  }

  @Test func refusedDefaultRestoresThePreviousRegistrationWithoutSaving() {
    let hotKeys = FakeHotKeys()
    let m = model("one", hotKeys)
    m.showShortcuts()
    m.setRecording(.openEnteAuth)
    let custom = KeyCombo(j, [.control, .option])
    _ = m.handleKeyPress(custom)
    m.clearShortcut(.lock)
    let saved = preferences.data(forKey: preferenceKey)
    hotKeys.refused = [open]
    m.restoreDefaultShortcuts()
    #expect(m.keymap.combo(for: .openEnteAuth) == custom)
    #expect(m.keymap.combo(for: .lock) == nil)
    #expect(hotKeys.registered == custom)
    #expect(hotKeys.calls == [open, nil, custom, open, custom])
    #expect(preferences.data(forKey: preferenceKey) == saved)
    #expect(m.unavailableGlobalShortcut == open)
    #expect(ShortcutProblem.unavailable(open).message(in: us) == "Couldn't register ⌥⌘E. Try a different shortcut.")
  }

  @Test func clearingAnOverrideProbesTheGlobalDefaultItRestores() {
    let stored = Data(#"{"lock":{"key":14,"modifiers":10}}"#.utf8)
    preferences.set(stored, forKey: preferenceKey)
    let hotKeys = FakeHotKeys()
    hotKeys.refused = [open]
    let m = model("one", hotKeys)
    #expect(m.keymap.combo(for: .openEnteAuth) == nil)
    #expect(m.keymap.combo(for: .lock) == open)
    m.showShortcuts()
    m.clearShortcut(.lock)
    #expect(m.keymap.combo(for: .openEnteAuth) == nil)
    #expect(m.keymap.combo(for: .lock) == open)
    #expect(preferences.data(forKey: preferenceKey) == stored)
    #expect(hotKeys.calls == [open])
    #expect(hotKeys.registered == nil)
    #expect(m.unavailableGlobalShortcut == open)
  }

  @Test func launchRefusalWarnsWithoutWritingAndPanelEditsStillSave() {
    let hotKeys = FakeHotKeys()
    hotKeys.refused = [open]
    let m = model("one", hotKeys)
    #expect(m.unavailableGlobalShortcut == open)
    #expect(m.keymap.combo(for: .openEnteAuth) == open)
    #expect(preferences.object(forKey: preferenceKey) == nil)
    #expect(hotKeys.calls == [open])
    m.showShortcuts()
    m.clearShortcut(.copyNextCode)
    #expect(model().keymap.combo(for: .copyNextCode) == nil)
    #expect(m.unavailableGlobalShortcut == open)
    m.setRecording(.syncNow)
    #expect(m.handleKeyPress(KeyCombo(y, .command)) == true)
    #expect(m.shortcutEditor == .browsing)
    #expect(model().keymap.combo(for: .syncNow) == KeyCombo(y, .command))
    #expect(m.unavailableGlobalShortcut == open)
    m.clearShortcut(.openEnteAuth)
    #expect(m.unavailableGlobalShortcut == nil)
    #expect(hotKeys.calls == [open, open, open])
  }

  @Test func clearingAndRestoringDefaults() {
    let hotKeys = FakeHotKeys()
    let m = model("one", hotKeys)
    m.showShortcuts()
    m.clearShortcut(.openEnteAuth)
    m.clearShortcut(.copyNextCode)
    #expect(m.keymap.combo(for: .openEnteAuth) == nil)
    #expect(m.keymap.isDefault == false)
    #expect(model().keymap.combo(for: .copyNextCode) == nil)
    m.restoreDefaultShortcuts()
    #expect(m.keymap.isDefault == true)
    #expect(model().keymap.isDefault == true)
    #expect(hotKeys.calls == [open, nil, open])
  }

  @Test func legacyOptOutSurvivesMissingAndUndecodableNewPreferences() {
    preferences.set(false, forKey: "globalShortcut.\(root.appending(path: "one").path)")
    let hotKeys = FakeHotKeys()
    let m = model("one", hotKeys)
    #expect(m.keymap.combo(for: .openEnteAuth) == nil)
    #expect(m.keymap.combo(for: .syncNow) == sync)
    #expect(hotKeys.calls == [])
    #expect(preferences.data(forKey: preferenceKey) == nil)
    preferences.set(Data("not json".utf8), forKey: preferenceKey)
    #expect(model().keymap.combo(for: .openEnteAuth) == nil)
    #expect(preferences.data(forKey: preferenceKey) == Data("not json".utf8))
    #expect(model("two").keymap.combo(for: .openEnteAuth) == open)
    m.showShortcuts()
    m.restoreDefaultShortcuts()
    #expect(model().keymap.combo(for: .openEnteAuth) == open)
    #expect(preferences.object(forKey: "globalShortcut.\(root.appending(path: "one").path)") as? Bool == false)
  }

  @Test func editingAnotherActionDoesNotPersistAResolvedDefaultCollision() throws {
    preferences.set(Data(#"{"lock":{"key":15,"modifiers":8}}"#.utf8), forKey: preferenceKey)
    let m = model()
    #expect(m.keymap.combo(for: .syncNow) == nil)
    #expect(m.keymap.combo(for: .lock) == sync)
    m.showShortcuts()
    m.setRecording(.copyNextCode)
    _ = m.handleKeyPress(KeyCombo(k, .command))
    let stored = try #require(preferences.data(forKey: preferenceKey))
    let json = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    #expect(Set(json.keys) == ["lock", "copyNextCode"])
    #expect(model().keymap.combo(for: .syncNow) == nil)
    #expect(model().keymap.combo(for: .copyNextCode) == KeyCombo(k, .command))
  }

  @Test func openingTheEditorRequestsAnOpenAndPanelKeysAreConsumedInEveryPhase() {
    let m = model()
    var opens = 0
    m.onOpen = { opens += 1 }
    m.showShortcuts()
    m.showShortcuts()
    #expect(opens == 2)
    #expect(m.shortcutEditor == .browsing)
    m.closeShortcuts()
    #expect(m.handleKeyPress(sync) == true)
    #expect(m.handleKeyPress(KeyCombo(.return, .command)) == true)
    #expect(m.handleKeyPress(lock) == true)
    #expect(m.handleKeyPress(open) == false)
    #expect(m.handleKeyPress(KeyCombo(.c, .command)) == false)
  }
}
