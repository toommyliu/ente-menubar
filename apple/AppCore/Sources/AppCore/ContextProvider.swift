import AppKit
import Foundation

@MainActor public protocol ContextProvider: AnyObject {
  var application: ApplicationContext? { get }
  func context(for application: ApplicationContext, websiteSuggestions: Bool) async -> ForegroundContext
}

@MainActor public final class LiveContextProvider: NSObject, ContextProvider {
  public private(set) var application: ApplicationContext?
  private let ownBundleID: String?

  public override init() {
    ownBundleID = Bundle.main.bundleIdentifier
    super.init()
    remember(NSWorkspace.shared.frontmostApplication)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(activated(_:)),
      name: NSWorkspace.didActivateApplicationNotification, object: nil)
  }

  @objc private func activated(_ notification: Notification) {
    remember(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
  }

  private func remember(_ app: NSRunningApplication?) {
    guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      let bundleID = app.bundleIdentifier, bundleID != ownBundleID
    else { return }
    application = ApplicationContext(bundleID: bundleID, name: app.localizedName ?? bundleID)
  }

  public func context(
    for application: ApplicationContext, websiteSuggestions: Bool
  ) async -> ForegroundContext {
    guard websiteSuggestions, application.isBrowser else {
      return ForegroundContext(application: application)
    }
    let hostname = await Task.detached(priority: .userInitiated) {
      Self.browserHostname(bundleID: application.bundleID)
    }.value
    return ForegroundContext(application: application, hostname: hostname)
  }

  private nonisolated static func browserHostname(bundleID: String) -> String? {
    guard ApplicationContext.browserBundleIDs.contains(bundleID) else { return nil }
    let property = bundleID == "com.apple.Safari"
      ? "URL of current tab of front window" : "URL of active tab of front window"
    let source = """
      with timeout of 1 second
        if application id "\(bundleID)" is running then
          tell application id "\(bundleID)" to return \(property)
        end if
      end timeout
      """
    guard let script = NSAppleScript(source: source) else { return nil }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    guard error == nil, let text = result.stringValue,
      let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host, !host.isEmpty
    else { return nil }
    return host.lowercased()
  }
}
