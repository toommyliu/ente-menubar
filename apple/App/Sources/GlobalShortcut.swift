import AppKit
import Carbon

@MainActor final class GlobalShortcut {
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: () -> Void

  init(action: @escaping () -> Void) { self.action = action }

  func setEnabled(_ enabled: Bool) -> String? {
    if !enabled { stop(); return nil }
    if hotKey != nil { return nil }
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
    guard installed == noErr else { return "Unable to enable the global shortcut (\(installed))." }
    let registered = RegisterEventHotKey(UInt32(kVK_ANSI_E), UInt32(optionKey | cmdKey),
                                       EventHotKeyID(signature: 0x454E5445, id: 1),
                                       GetApplicationEventTarget(), 0, &hotKey)
    guard registered == noErr else {
      stop()
      return "Unable to register ⌥⌘E. Another app may be using it (\(registered))."
    }
    return nil
  }

  func stop() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
    hotKey = nil
    handler = nil
  }
}
