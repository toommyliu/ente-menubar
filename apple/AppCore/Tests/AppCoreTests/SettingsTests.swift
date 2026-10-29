import AppKit
import EnteBridge
import Foundation
import Testing

@testable import AppCore

@MainActor final class TestLoginItem: LoginItemManaging {
  var status: LoginItemStatus = .notRegistered
  var needsApproval = false
  var settingsOpened = 0

  func setEnabled(_ enabled: Bool) throws {
    status = enabled ? (needsApproval ? .requiresApproval : .enabled) : .notRegistered
  }

  func openSettings() { settingsOpened += 1 }
}

@Suite @MainActor struct SettingsTests {
  @Test func maskingKeepsNumericGroupingAndSteamLength() {
    #expect(CodePresentation("123456", hidden: true).text == "••• •••")
    #expect(CodePresentation("12345678", hidden: true).text == "•••• ••••")
    #expect(CodePresentation("PV9M4", hidden: true).text == "•••••")
    #expect(CodePresentation("PV9M4", hidden: true).accessibilityLabel == "hidden code")
    #expect(CodePresentation("123456", hidden: true).accessibilityLabel == "hidden code")
    #expect(CodePresentation("12345678", hidden: false).text == "1234 5678")
    #expect(CodePresentation("123456", hidden: false).accessibilityLabel == "123 456")
  }

  @Test func preferencesRoundTripWithinProfileAndOptionResetsOnClose() throws {
    let suite = "u8-settings-\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appending(path: suite)
    func model(_ profile: String) -> AppModel {
      AppModel(cacheStore: CacheStore(url: root.appending(path: "\(profile)/cache.bin")),
               contextProvider: FakeContextProvider(), preferences: preferences, loginItem: TestLoginItem())
    }
    let original = model("one")
    original.setHideCodes(true)
    original.setWebsiteSuggestions(true)
    original.setShowSuggestions(false)
    original.setGlobalShortcutEnabled(false)
    let restored = model("one")
    #expect(restored.hideCodes == true)
    #expect(restored.websiteSuggestions == true)
    #expect(restored.showSuggestions == false)
    #expect(restored.globalShortcutEnabled == false)
    let other = model("two")
    #expect(other.hideCodes == false)
    #expect(other.websiteSuggestions == false)
    #expect(other.showSuggestions == true)
    #expect(other.globalShortcutEnabled == true)
    restored.setVisible(true)
    restored.setOptionHeld(true)
    #expect(restored.codesHidden == false)
    restored.setOptionHeld(false)
    #expect(restored.codesHidden == true)
    restored.setOptionHeld(true)
    restored.setVisible(false)
    #expect(restored.codesHidden == true)
    restored.setVisible(true)
    #expect(restored.codesHidden == true)
    restored.setHideCodes(false)
    restored.setWebsiteSuggestions(false)
    restored.setShowSuggestions(true)
    restored.setGlobalShortcutEnabled(true)
    let reset = model("one")
    #expect(reset.hideCodes == false)
    #expect(reset.websiteSuggestions == false)
    #expect(reset.showSuggestions == true)
    #expect(reset.globalShortcutEnabled == true)
  }

  @Test func launchAtLoginReadsActualStatusAndOpensApprovalSettings() {
    let service = TestLoginItem()
    let model = AppModel(contextProvider: FakeContextProvider(), loginItem: service)
    model.toggleLaunchAtLogin()
    #expect(model.loginItemStatus == .enabled)
    model.toggleLaunchAtLogin()
    #expect(model.loginItemStatus == .notRegistered)
    service.needsApproval = true
    model.toggleLaunchAtLogin()
    #expect(model.loginItemStatus == .requiresApproval)
    #expect(service.settingsOpened == 1)
    model.toggleLaunchAtLogin()
    #expect(service.settingsOpened == 2)
    service.status = .enabled
    model.refreshLoginItemStatus()
    #expect(model.loginItemStatus == .enabled)
  }

  @Test func selectedSixtySecondCodeControlsCountdownAndNextPreview() {
    func timed(_ id: String, _ period: UInt64, _ remaining: UInt64) -> CodeView {
      CodeView(id: id, issuer: id, account: "alice", kind: .totp, current: "123456", next: "234567",
               periodSecs: period, remainingMs: remaining, display: discoveryCode(id, id).display)
    }
    let early: [DiscoveryRow] = [.code(.pinned, timed("legacy", 60, 33000)), .code(.all, timed("rfc", 30, 3000))]
    let timing = CodeTiming.selected(in: early, selection: .code(.pinned, "legacy"))
    #expect(timing?.code.periodSecs == 60)
    #expect(timing?.code.remainingMs == 33000)
    #expect(timing?.isExpiring == false)
    #expect(timing?.remaining(at: Date(timeIntervalSince1970: 27), sampledAt: Date(timeIntervalSince1970: 27)) == 33)
    let late: [DiscoveryRow] = [.code(.pinned, timed("legacy", 60, 3000)), .code(.all, timed("rfc", 30, 3000))]
    #expect(CodeTiming.selected(in: late, selection: .code(.pinned, "legacy"))?.isExpiring == true)
    #expect(CodeTiming.selected(in: late, selection: .code(.pinned, "legacy"))?.code.remainingMs == 3000)
    #expect(CodeTiming.selected(in: early, selection: nil)?.code.id == "legacy")
    #expect(CodeTiming.selected(in: [.showAll(20)], selection: .showAll) == nil)
    let hotp = CodeView(id: "hotp", issuer: "Counter", account: "alice", kind: .hotp, current: "", next: "",
                        periodSecs: 0, remainingMs: 0, display: discoveryCode("hotp", "Counter").display)
    #expect(CodeTiming.selected(in: early + [.code(.all, hotp)], selection: .code(.all, "hotp")) == nil)
  }

  @Test func dismissalsPersistAndBlockLearningNamesAndIconsOnlyHere() throws {
    let instant = Date(timeIntervalSince1970: 59)
    let github = discoveryCode("github", "GitHub")
    let other = discoveryCode("other", "Other")
    let context = ForegroundContext(application: ApplicationContext(bundleID: "browser", name: "Browser"), hostname: "github.com")
    var usage = UsageHistory()
    usage.record(github, context: context, at: instant)
    #expect(contextMatches([github, other], context: context, usage: usage, now: instant).map(\.id) == ["github"])
    usage.dismiss(github, context: context)
    let directory = FileManager.default.temporaryDirectory.appending(path: "u8-dismiss-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UsageStore(cacheURL: directory.appending(path: "cache.bin"))
    try store.save(usage)
    var restored = try store.load()
    #expect(restored.codes["github"]?.dismissedContexts == ["github.com"])
    #expect(restored.codes["github"]?.contexts["github.com"] == nil)
    restored.record(github, context: context, at: instant)
    #expect(restored.codes["github"]?.contexts["github.com"] == nil)
    #expect(contextMatches([github, other], context: context, usage: restored, now: instant).map(\.id) == [])
    let app = ForegroundContext(application: ApplicationContext(bundleID: "github.app", name: "GitHub"))
    #expect(contextMatches([github, other], context: app, usage: restored, now: instant).map(\.id) == ["github"])
    restored.dismiss(github, context: app)
    #expect(contextMatches([github, other], context: app, usage: restored, now: instant).map(\.id) == [])
    let alias = discoveryCode("alias", "Amazon Web Services")
    let aws = ForegroundContext(application: context.application, hostname: "aws.amazon.com")
    let icon = ServiceIcon(source: .custom, slug: "aws", hex: nil)
    let catalog = IconCatalog(custom: ["amazonwebservices": icon, "aws": icon], simple: [:])
    #expect(contextMatches([alias], context: aws, usage: restored, now: instant, catalog: catalog).map(\.id) == ["alias"])
    restored.dismiss(alias, context: aws)
    #expect(contextMatches([alias], context: aws, usage: restored, now: instant, catalog: catalog).map(\.id) == [])
    let hidden = discoveryRows(codes: [github, other], query: "", usage: UsageHistory(), context: context,
                               websiteSuggestions: true, allExpanded: false, now: instant, showSuggestions: false)
    #expect(hidden.map(\.id) == [.header(.all), .code(.all, "github"), .code(.all, "other")])
    let visible = discoveryRows(codes: [github, other], query: "", usage: UsageHistory(), context: context,
                                websiteSuggestions: true, allExpanded: false, now: instant, showSuggestions: true)
    #expect(visible.map(\.id) == [.header(.suggested), .code(.suggested, "github"), .header(.other), .code(.all, "other")])
  }
}
