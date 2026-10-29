import AppCore
import AppKit
import SwiftUI

@MainActor final class StatusItemController: NSObject, NSWindowDelegate {
  private let model: AppModel
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let panel = CodePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  private let accountMenu: AccountMenu
  private lazy var hotKey = GlobalShortcut { [weak self] in self?.toggle() }
  private var localMonitor: Any?
  private var outsideMonitor: Any?
  private var isOpen = false
  private var fadeGeneration = 0

  init(model: AppModel) {
    self.model = model
    accountMenu = AccountMenu(model: model)
    super.init()
    let button = statusItem.button!
    button.image = NSImage(named: "MenuBarIcon")
    button.setAccessibilityLabel("Ente Auth")
    button.toolTip = "Ente Auth"
    button.target = self
    button.action = #selector(clicked)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    panel.delegate = self
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.becomesKeyOnlyIfNeeded = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.title = "Ente Auth"
    let host = PopoverHost(rootView: PopoverView(model: model).clipShape(RoundedRectangle(cornerRadius: 10))
      .frame(maxHeight: .infinity, alignment: .top))
    panel.contentView = host
    panel.setContentSize(host.fittingSize)
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        guard let self, self.isOpen else { return false }
        if event.type == .flagsChanged {
          let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
          self.model.setOptionHeld(self.panel.isKeyWindow && modifiers == .option)
        } else if event.type == .keyDown, event.window === self.panel {
          if self.accountMenu.handleKeyEquivalent(event) { return true }
        } else if event.type != .keyDown, event.window !== self.panel,
                  event.window !== self.statusItem.button?.window {
          self.dismissForOutsideClick()
        }
        return false
      }
      return handled ? nil : event
    }
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismissForOutsideClick() }
    }
    model.configureGlobalShortcut { [weak self] in self?.hotKey.setEnabled($0) }
    model.onClose = { [weak self] in self?.close() }
    model.onUnlockFinished = { [weak self] in self?.focusPanel() }
  }

  @objc private func clicked() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      close()
      statusItem.menu = accountMenu.menu
      statusItem.button?.performClick(nil)
      statusItem.menu = nil
    } else { toggle() }
  }

  private func toggle() {
    if isOpen { close(); return }
    guard let button = statusItem.button, let window = button.window else { return }
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    let screen = window.screen?.visibleFrame ?? anchor
    let size = panel.contentView?.fittingSize ?? NSSize(width: 348, height: 180)
    panel.setFrame(NSRect(x: min(max(anchor.midX - size.width / 2, screen.minX), screen.maxX - size.width),
                          y: anchor.minY - size.height - 5, width: size.width, height: size.height), display: false)
    fadeGeneration += 1
    isOpen = true
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
    model.setVisible(true)
    model.setOptionHeld(false)
    focusPanel()
  }

  private func focusPanel() {
    guard isOpen else { return }
    panel.makeKey()
    panel.contentView?.layoutSubtreeIfNeeded()
    if let field = panel.contentView.flatMap(Self.firstTextField) { panel.makeFirstResponder(field) }
  }

  private static func firstTextField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { firstTextField(in: $0) }.first
  }

  func windowDidResignKey(_ notification: Notification) {
    model.setOptionHeld(false)
    if case .unlocking = model.phase { return }
    close()
  }

  private func dismissForOutsideClick() {
    if case .unlocking = model.phase { return }
    close()
  }

  private func close() {
    model.setOptionHeld(false)
    model.setVisible(false)
    guard isOpen else { return }
    isOpen = false
    fadeGeneration += 1
    let generation = fadeGeneration
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.1
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.fadeGeneration == generation else { return }
        self.panel.orderOut(nil)
        self.panel.alphaValue = 1
      }
    })
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }

  func stop() {
    hotKey.stop()
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    NSStatusBar.system.removeStatusItem(statusItem)
  }
}

private final class CodePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

private final class PopoverHost<Content: View>: NSHostingView<Content> {
  private var targetSize: NSSize?

  override func layout() {
    super.layout()
    guard let window else { return }
    let size = fittingSize
    guard size != targetSize else { return }
    let animate = targetSize != nil && window.isVisible
    targetSize = size
    let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
    guard animate else {
      window.setFrame(frame, display: true)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      window.animator().setFrame(frame, display: true)
    }
  }
}
