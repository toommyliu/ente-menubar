import AppKit
import ServiceManagement
import SwiftUI

public enum LoginItemStatus: Equatable {
  case notRegistered, enabled, requiresApproval, unavailable
}

@MainActor public protocol LoginItemManaging: AnyObject {
  var status: LoginItemStatus { get }
  func setEnabled(_ enabled: Bool) throws
  func openSettings()
}

@MainActor final class SystemLoginItem: LoginItemManaging {
  var status: LoginItemStatus {
    switch SMAppService.mainApp.status {
    case .notRegistered: .notRegistered
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notFound: .unavailable
    @unknown default: .unavailable
    }
  }

  func setEnabled(_ enabled: Bool) throws {
    if enabled { try SMAppService.mainApp.register() }
    else { try SMAppService.mainApp.unregister() }
  }

  func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor public final class AccountMenu: NSObject, NSMenuDelegate {
  public let menu = NSMenu()
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
    super.init()
    menu.delegate = self
    rebuild()
  }

  public func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

  private func rebuild() {
    model.refreshLoginItemStatus()
    menu.removeAllItems()
    add("Sync Now", #selector(sync), shortcut: model.keymap.combo(for: .syncNow), enabled: ready)
    add("Lock", #selector(lock), shortcut: model.keymap.combo(for: .lock), enabled: ready)
    menu.addItem(.separator())
    add("Hide Codes", #selector(hideCodes), checked: model.hideCodes)
    add("Show Suggestions", #selector(showSuggestions), checked: model.showSuggestions)
    add("Suggest Codes for Websites", #selector(websites), checked: model.websiteSuggestions)
    add(model.loginItemStatus == .requiresApproval ? "Launch at Login (Needs Approval…)" : "Launch at Login",
        #selector(login), checked: model.loginItemStatus == .enabled)
    add("Keyboard Shortcuts…", #selector(shortcuts))
    menu.addItem(.separator())
    add("Sign Out", #selector(signOut), enabled: signedIn)
    add("Quit", #selector(quit))
    menu.items.last?.keyEquivalent = "q"
    menu.items.last?.keyEquivalentModifierMask = .command
  }

  private var ready: Bool {
    if case .ready = model.phase { return true }
    return false
  }

  private var signedIn: Bool {
    switch model.phase {
    case .ready, .locked, .unlocking: true
    case .launching, .signedOut: false
    }
  }

  private func add(
    _ title: String, _ action: Selector, shortcut: KeyCombo? = nil, checked: Bool = false, enabled: Bool = true
  ) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.setShortcut(shortcut, in: .current)
    item.target = self
    item.state = checked ? .on : .off
    item.isEnabled = enabled
    menu.addItem(item)
    menu.autoenablesItems = false
  }

  @objc private func sync() { Task { await model.sync() } }
  @objc private func lock() { model.lock() }
  @objc private func hideCodes() { model.setHideCodes(!model.hideCodes) }
  @objc private func showSuggestions() { model.setShowSuggestions(!model.showSuggestions) }
  @objc private func websites() { model.setWebsiteSuggestions(!model.websiteSuggestions) }
  @objc private func login() { model.toggleLaunchAtLogin() }
  @objc private func shortcuts() { model.showShortcuts() }
  @objc private func signOut() { Task { await model.signOut() } }
  @objc private func quit() { NSApp.terminate(nil) }
}

struct AccountMenuButton: NSViewRepresentable {
  let model: AppModel

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton()
    button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Account menu")
    button.target = context.coordinator
    button.action = #selector(Coordinator.open(_:))
    button.isBordered = false
    button.setAccessibilityLabel("Account menu")
    return button
  }

  func updateNSView(_ nsView: NSButton, context: Context) {}

  @MainActor final class Coordinator: NSObject {
    let accountMenu: AccountMenu
    init(model: AppModel) { accountMenu = AccountMenu(model: model) }
    @objc func open(_ sender: NSButton) {
      accountMenu.menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY), in: sender)
    }
  }
}
