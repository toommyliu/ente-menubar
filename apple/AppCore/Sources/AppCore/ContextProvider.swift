import AppKit
import CoreServices
import Foundation

@MainActor public protocol ContextProvider: AnyObject {
  var application: ApplicationContext? { get }
  func context(for application: ApplicationContext, websiteSuggestions: Bool) async -> ForegroundContext
  func requestWebsiteAccess(for application: ApplicationContext) async
  func openWebsiteAccessSettings()
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
    return await Task.detached(priority: .userInitiated) {
      let access = Self.websiteAccess(bundleID: application.bundleID, ask: false)
      let hostname = access == .allowed ? Self.browserHostname(bundleID: application.bundleID) : nil
      return ForegroundContext(application: application, hostname: hostname, websiteAccess: access)
    }.value
  }

  public func requestWebsiteAccess(for application: ApplicationContext) async {
    await Task.detached(priority: .userInitiated) {
      _ = Self.websiteAccess(bundleID: application.bundleID, ask: true)
    }.value
  }

  public func openWebsiteAccessSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")!)
  }

  private nonisolated static func websiteAccess(bundleID: String, ask: Bool) -> WebsiteAccess? {
    var target = AEAddressDesc()
    let status = bundleID.withCString {
      AECreateDesc(DescType(typeApplicationBundleID), $0, bundleID.utf8.count, &target)
    }
    guard status == noErr else { return nil }
    defer { AEDisposeDesc(&target) }
    switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
    case noErr: return .allowed
    case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
    case OSStatus(errAEEventNotPermitted): return .denied
    default: return nil
    }
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
