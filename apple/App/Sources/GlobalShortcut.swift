import AppCore
import AppKit
import Carbon

struct GlobalShortcutError: Error {
  let status: OSStatus
}

@MainActor final class GlobalShortcut {
  private var registered: KeyCombo?
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: () -> Void

  init(action: @escaping () -> Void) { self.action = action }

  func register(_ combo: KeyCombo?) throws {
    if combo == registered { return }
    stop()
    guard let combo else { return }
    var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
      guard let data, let event else { return OSStatus(eventNotHandledErr) }
      var id = EventHotKeyID()
      let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
      guard status == noErr, id.signature == 0x454E5445, id.id == 1 else { return OSStatus(eventNotHandledErr) }
      MainActor.assumeIsolated {
        Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue().action()
      }
      return noErr
    }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard installed == noErr else {
      stop()
      throw GlobalShortcutError(status: installed)
    }
    let status = RegisterEventHotKey(UInt32(combo.key.rawValue), carbonModifiers(combo.modifiers),
                                     EventHotKeyID(signature: 0x454E5445, id: 1),
                                     GetApplicationEventTarget(), 0, &hotKey)
    guard status == noErr else {
      stop()
      throw GlobalShortcutError(status: status)
    }
    registered = combo
  }

  func stop() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
    hotKey = nil
    handler = nil
    registered = nil
  }

  private func carbonModifiers(_ modifiers: KeyCombo.Modifiers) -> UInt32 {
    var flags = 0
    if modifiers.contains(.command) { flags |= cmdKey }
    if modifiers.contains(.option) { flags |= optionKey }
    if modifiers.contains(.control) { flags |= controlKey }
    if modifiers.contains(.shift) { flags |= shiftKey }
    return UInt32(flags)
  }
}
