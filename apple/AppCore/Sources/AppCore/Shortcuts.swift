import AppKit
import Carbon.HIToolbox

public struct KeyCode: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }
  public init(_ virtualKey: Int) { rawValue = UInt16(virtualKey) }

  static let a = KeyCode(kVK_ANSI_A)
  static let c = KeyCode(kVK_ANSI_C)
  static let e = KeyCode(kVK_ANSI_E)
  static let l = KeyCode(kVK_ANSI_L)
  static let q = KeyCode(kVK_ANSI_Q)
  static let r = KeyCode(kVK_ANSI_R)
  static let v = KeyCode(kVK_ANSI_V)
  static let x = KeyCode(kVK_ANSI_X)
  static let z = KeyCode(kVK_ANSI_Z)
  static let `return` = KeyCode(kVK_Return)
  static let escape = KeyCode(kVK_Escape)
  static let tab = KeyCode(kVK_Tab)
}

public struct KeyCombo: Hashable, Codable, Sendable {
  public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)

    public init(_ flags: NSEvent.ModifierFlags) {
      self = []
      if flags.contains(.control) { insert(.control) }
      if flags.contains(.option) { insert(.option) }
      if flags.contains(.shift) { insert(.shift) }
      if flags.contains(.command) { insert(.command) }
    }

    var eventFlags: NSEvent.ModifierFlags {
      var flags: NSEvent.ModifierFlags = []
      if contains(.control) { flags.insert(.control) }
      if contains(.option) { flags.insert(.option) }
      if contains(.shift) { flags.insert(.shift) }
      if contains(.command) { flags.insert(.command) }
      return flags
    }
  }

  public let key: KeyCode
  public let modifiers: Modifiers

  public init(_ key: KeyCode, _ modifiers: Modifiers) {
    self.key = key
    self.modifiers = modifiers
  }

  public init(event: NSEvent) { self.init(KeyCode(rawValue: event.keyCode), Modifiers(event.modifierFlags)) }

  static let escape = KeyCombo(.escape, [])
  static let tab = KeyCombo(.tab, [])

  var hasModifier: Bool { !modifiers.isDisjoint(with: [.command, .option, .control]) }

  func label(in layout: KeyLayout) -> String {
    let prefix = [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { modifiers.contains($0.0) }.map(\.1).joined()
    return prefix + (specialKeys[key]?.symbol
      ?? layout.character(key, modifiers.contains(.command))?.uppercased() ?? "#\(key.rawValue)")
  }
}

enum ShortcutAction: String, CaseIterable, Codable, Sendable {
  case openEnteAuth, copyNextCode, syncNow, lock

  var title: String {
    switch self {
    case .openEnteAuth: "Open Ente Auth"
    case .copyNextCode: "Copy Next Code"
    case .syncNow: "Sync Now"
    case .lock: "Lock"
    }
  }

  var isGlobal: Bool { self == .openEnteAuth }

  var defaultCombo: KeyCombo {
    switch self {
    case .openEnteAuth: KeyCombo(.e, [.option, .command])
    case .copyNextCode: KeyCombo(.return, .command)
    case .syncNow: KeyCombo(.r, .command)
    case .lock: KeyCombo(.l, .command)
    }
  }
}

struct Keymap: Equatable {
  private var overrides: [ShortcutAction: KeyCombo?] = [:]

  init() {}

  init?(stored: Data?) {
    guard let stored, let decoded = try? JSONDecoder().decode([String: KeyCombo?].self, from: stored) else { return nil }
    var seen: Set<KeyCombo> = []
    for action in ShortcutAction.allCases {
      guard let entry = decoded[action.rawValue] else { continue }
      if let combo = entry {
        guard combo.hasModifier, seen.insert(combo).inserted else { continue }
      }
      overrides[action] = .some(entry)
    }
  }

  var stored: Data {
    let entries = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
    return try! JSONEncoder().encode(entries)
  }

  var isDefault: Bool { overrides.isEmpty }

  func combo(for action: ShortcutAction) -> KeyCombo? {
    if let override = overrides[action] { return override }
    let combo = action.defaultCombo
    return overrides.contains { $0.key != action && $0.value == combo } ? nil : combo
  }

  func action(for combo: KeyCombo) -> ShortcutAction? {
    ShortcutAction.allCases.first { self.combo(for: $0) == combo }
  }

  mutating func assign(_ combo: KeyCombo, to action: ShortcutAction, in layout: KeyLayout) throws(ShortcutProblem) {
    guard combo.hasModifier else { throw .needsModifier }
    if layout.reservedReason(for: combo) != nil { throw .reserved(combo) }
    if let owner = self.action(for: combo), owner != action { throw .taken(combo, by: owner) }
    if combo == action.defaultCombo { overrides.removeValue(forKey: action) }
    else { overrides[action] = .some(combo) }
  }

  mutating func clear(_ action: ShortcutAction) { overrides[action] = .some(nil) }
}

enum ShortcutProblem: Error, Equatable {
  case needsModifier
  case reserved(KeyCombo)
  case taken(KeyCombo, by: ShortcutAction)
  case unavailable(KeyCombo)

  func message(in layout: KeyLayout) -> String {
    switch self {
    case .needsModifier: "Shortcuts need ⌘, ⌥, or ⌃."
    case .reserved(let combo): "\(combo.label(in: layout)) \(layout.reservedReason(for: combo) ?? "is reserved")."
    case .taken(let combo, let owner): "\(combo.label(in: layout)) is already used by \(owner.title)."
    case .unavailable(let combo): "Couldn't register \(combo.label(in: layout)). Try a different shortcut."
    }
  }
}

struct KeyLayout {
  private let translate: (KeyCode, _ command: Bool) -> String?

  init(_ translate: @escaping (KeyCode, _ command: Bool) -> String?) { self.translate = translate }
  init(characters: [KeyCode: String]) { translate = { key, _ in characters[key] } }

  @MainActor static var current: KeyLayout {
    let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
    guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
      return KeyLayout(characters: [:])
    }
    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    let keyboardType = UInt32(LMGetKbdType())
    return KeyLayout { key, command in
      data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return nil }
        let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, key.rawValue, UInt16(kUCKeyActionDisplay),
          command ? UInt32(cmdKey >> 8) : 0, keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
          &deadKey, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
      }
    }
  }

  func character(_ key: KeyCode, _ command: Bool) -> String? { translate(key, command) }

  func reservedReason(for combo: KeyCombo) -> String? {
    guard let character = character(combo.key, true)?.lowercased() else { return nil }
    if combo.modifiers == [.shift, .command], character == "z" { return "redoes typing in search" }
    guard combo.modifiers == .command else { return nil }
    switch character {
    case "a": return "selects all text in search"
    case "c": return "copies text in search"
    case "v": return "pastes into search"
    case "x": return "cuts text in search"
    case "z": return "undoes typing in search"
    case "q": return "quits Ente Auth"
    default: return nil
    }
  }
}

private let specialKeys: [KeyCode: (symbol: String, equivalent: String)] = {
  var keys: [KeyCode: (String, String)] = [
    .return: ("↩", "\r"), .escape: ("⎋", "\u{1b}"), .tab: ("⇥", "\t"),
    KeyCode(kVK_Space): ("Space", " "), KeyCode(kVK_Delete): ("⌫", "\u{8}"),
    KeyCode(kVK_ForwardDelete): ("⌦", String(UnicodeScalar(NSDeleteFunctionKey)!)),
    KeyCode(kVK_UpArrow): ("↑", String(UnicodeScalar(NSUpArrowFunctionKey)!)),
    KeyCode(kVK_DownArrow): ("↓", String(UnicodeScalar(NSDownArrowFunctionKey)!)),
    KeyCode(kVK_LeftArrow): ("←", String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
    KeyCode(kVK_RightArrow): ("→", String(UnicodeScalar(NSRightArrowFunctionKey)!)),
    KeyCode(kVK_Home): ("↖", String(UnicodeScalar(NSHomeFunctionKey)!)),
    KeyCode(kVK_End): ("↘", String(UnicodeScalar(NSEndFunctionKey)!)),
    KeyCode(kVK_PageUp): ("⇞", String(UnicodeScalar(NSPageUpFunctionKey)!)),
    KeyCode(kVK_PageDown): ("⇟", String(UnicodeScalar(NSPageDownFunctionKey)!)),
    KeyCode(kVK_ANSI_KeypadEnter): ("⌤", String(UnicodeScalar(NSEnterCharacter)!)),
  ]
  let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
  for (index, key) in functionKeys.enumerated() {
    keys[KeyCode(key)] = ("F\(index + 1)", String(UnicodeScalar(NSF1FunctionKey + index)!))
  }
  return keys
}()

extension NSMenuItem {
  func setShortcut(_ combo: KeyCombo?, in layout: KeyLayout) {
    keyEquivalent = combo.map {
      specialKeys[$0.key]?.equivalent ?? layout.character($0.key, $0.modifiers.contains(.command))?.lowercased() ?? ""
    } ?? ""
    keyEquivalentModifierMask = combo?.modifiers.eventFlags ?? []
  }
}
