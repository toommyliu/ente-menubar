import AppKit
import EnteBridge
import Foundation
import Testing

@testable import AppCore

@MainActor final class FakeContextProvider: ContextProvider {
  var application: ApplicationContext?
  var hostname: String?
  var delay: Duration = .zero
  var access: WebsiteAccess = .allowed
  var answer: WebsiteAccess = .allowed
  var requestDelay: Duration = .zero
  var promptApplication: ApplicationContext?
  private(set) var requests: [String] = []
  private(set) var settingsOpened = 0

  init(application: ApplicationContext? = nil, hostname: String? = nil) {
    self.application = application
    self.hostname = hostname
  }

  func context(for application: ApplicationContext, websiteSuggestions: Bool) async -> ForegroundContext {
    let host = hostname
    let access = access
    try? await Task.sleep(for: delay)
    return ForegroundContext(application: application,
      hostname: websiteSuggestions && access == .allowed ? host : nil,
      websiteAccess: websiteSuggestions && application.isBrowser ? access : nil)
  }

  func requestWebsiteAccess(for application: ApplicationContext) async {
    requests.append(application.bundleID)
    if let promptApplication { self.application = promptApplication }
    try? await Task.sleep(for: requestDelay)
    if access == .notAsked { access = answer }
  }

  func openWebsiteAccessSettings() { settingsOpened += 1 }
}

@Suite @MainActor struct DiscoveryModelTests {
  @Test func websiteAccessCanBeAllowedAndRestoredFromSettings() async throws {
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let directory = FileManager.default.temporaryDirectory.appending(path: "website-access-\(UUID())")
    let store = SessionStore(service: "website-access-\(UUID())", protection: .unprotectedForTests)
    let preferences = try #require(UserDefaults(suiteName: "website-access-\(UUID())"))
    defer {
      try? store.delete()
      try? FileManager.default.removeItem(at: directory)
    }
    let helium = ApplicationContext(bundleID: "net.imput.helium", name: "Helium")
    let fake = FakeContextProvider(application: helium, hostname: "login.example")
    fake.access = .notAsked
    fake.answer = .allowed
    fake.requestDelay = .milliseconds(100)
    fake.promptApplication = ApplicationContext(
      bundleID: "com.apple.UserNotificationCenter", name: "UserNotificationCenter")
    let model = AppModel(
      config: AppModel.configuration(environment: ["ENTE_MENUBAR_API_ORIGIN": museum.fixture.endpoint]),
      sessionStore: store, cacheStore: CacheStore(url: directory.appending(path: "cache.bin")),
      contextProvider: fake, preferences: preferences)
    var promptsFinished = 0
    model.onSystemPromptFinished = { promptsFinished += 1 }
    await model.launch()
    model.setVisible(true)
    model.setEmail(museum.fixture.email)
    await model.submit(password: museum.fixture.password)
    #expect(model.websiteSuggestions == false)
    #expect(model.rows.first(where: \.selectable)?.id == .websiteSetup)
    if case .websiteSetup(let setup) = model.rows.first(where: \.selectable) { #expect(setup == .turnOn) }
    else { Issue.record("Expected website opt-in") }
    model.activateSelection()
    #expect(model.websiteSuggestions == true)
    #expect(model.awaitingSystemPrompt == true)
    #expect(await eventually { fake.requests == ["net.imput.helium"] })
    #expect(model.awaitingSystemPrompt == true)
    #expect(promptsFinished == 0)
    #expect(await eventually { model.context?.hostname == "login.example" })
    #expect(fake.requests == ["net.imput.helium"])
    #expect(promptsFinished == 1)
    #expect(model.awaitingSystemPrompt == false)
    #expect(model.context?.application == helium)
    #expect(model.rows.contains { $0.id == .websiteSetup } == false)
    fake.application = helium
    fake.access = .denied
    model.setVisible(false)
    model.setVisible(true)
    #expect(await eventually { model.context?.websiteAccess == .denied })
    #expect(model.context?.hostname == nil)
    #expect(model.rows.first(where: \.selectable)?.id == .websiteSetup)
    if case .websiteSetup(let setup) = model.rows.first(where: \.selectable) {
      #expect(setup == .openSettings("Helium"))
    } else { Issue.record("Expected website access settings") }
    model.activateSelection()
    #expect(fake.settingsOpened == 1)
    #expect(fake.requests == ["net.imput.helium"])
    #expect(promptsFinished == 1)
    fake.access = .allowed
    model.setVisible(false)
    model.setVisible(true)
    #expect(await eventually { model.context?.hostname == "login.example" })
    #expect(model.rows.contains { $0.id == .websiteSetup } == false)
    #expect(model.awaitingSystemPrompt == false)
    await model.signOut()
  }

  @Test func copyingLearnsWebsiteAndAppPersistsUsageAndSuggestsOnNextOpen() async throws {
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let directory = FileManager.default.temporaryDirectory.appending(path: "discovery-model-\(UUID())")
    let store = SessionStore(service: "discovery-model-\(UUID())", protection: .unprotectedForTests)
    let preferences = try #require(UserDefaults(suiteName: "discovery-model-\(UUID())"))
    let cache = CacheStore(url: directory.appending(path: "cache.bin"))
    let usageStore = UsageStore(cacheURL: cache.url)
    let board = NSPasteboard(name: NSPasteboard.Name("discovery-model-\(UUID())"))
    defer {
      try? store.delete()
      try? FileManager.default.removeItem(at: directory)
      board.releaseGlobally()
    }
    let fake = FakeContextProvider(
      application: ApplicationContext(bundleID: "net.imput.helium", name: "Helium"),
      hostname: "login.example")
    fake.delay = .milliseconds(100)
    let instant = Date(timeIntervalSince1970: 59)
    let config = AppModel.configuration(environment: ["ENTE_MENUBAR_API_ORIGIN": museum.fixture.endpoint])
    let model = AppModel(config: config, sessionStore: store, cacheStore: cache, pasteboard: board,
      contextProvider: fake, preferences: preferences, now: { instant })
    #expect(model.websiteSuggestions == false)
    await model.launch()
    model.setVisible(true)
    model.setEmail(museum.fixture.email)
    await model.submit(password: museum.fixture.password)
    let id = try #require(model.filteredCodes.first { $0.issuer == "RFC" }?.id)
    #expect(model.rows.first(where: \.selectable)?.id == .websiteSetup)
    model.activateSelection()
    #expect(model.websiteSuggestions == true)
    #expect(model.context?.hostname == nil)
    #expect(await eventually { model.context?.hostname == "login.example" })
    model.search = "rfc"
    model.activateSelection()
    #expect(board.string(forType: .string) == "287082")
    let saved = try usageStore.load()
    #expect(saved.codes[id]?.activity.count == 8)
    #expect(saved.codes[id]?.activity.lastUsedAt == instant)
    #expect(saved.codes[id]?.contexts["login.example"]?.count == 1)
    model.copy()
    #expect(try usageStore.load().codes[id]?.contexts["login.example"]?.count == 2)
    model.search = ""
    #expect(model.rows.first?.id != .header(.suggested))
    model.setVisible(false)
    model.setVisible(true)
    #expect(model.search == "")
    #expect(model.context?.hostname == nil)
    await model.contextSettled(within: .seconds(1))
    #expect(model.context?.hostname == "login.example")
    #expect(model.rows.first?.id == .header(.suggested))
    #expect(model.rows.first(where: \.selectable)?.code?.id == id)
    model.search = "rfc"
    model.setVisible(false)
    fake.application = ApplicationContext(bundleID: "com.apple.Terminal", name: "Terminal")
    model.setVisible(true)
    model.search = "rfc"
    model.copy()
    model.copy()
    #expect(try usageStore.load().codes[id]?.contexts["com.apple.Terminal"]?.count == 2)
    model.setVisible(false)
    model.setVisible(true)
    #expect(model.rows.first(where: \.selectable)?.code?.id == id)
    #expect(model.rows.first?.id == .header(.suggested))
    model.dismissSuggestion(id: id)
    #expect(model.rows.first?.id == .header(.pinned))
    #expect(try usageStore.load().codes[id]?.contexts["com.apple.Terminal"] == nil)
    #expect(try usageStore.load().codes[id]?.dismissedContexts == ["com.apple.Terminal"])
    let relaunched = AppModel(config: config, sessionStore: store, cacheStore: cache, pasteboard: board,
      contextProvider: fake, preferences: preferences, now: { instant })
    #expect(relaunched.websiteSuggestions == true)
    #expect(relaunched.usage.codes[id]?.activity.count == 11)
    #expect(relaunched.usage.codes[id]?.dismissedContexts == ["com.apple.Terminal"])
    await model.signOut()
    #expect(try usageStore.file.load() == nil)
    #expect(model.usage.codes == [:])
  }

  @Test func keyboardTraversesActionsAndContextArrivingAfterCloseIsIgnored() async throws {
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let directory = FileManager.default.temporaryDirectory.appending(path: "discovery-keyboard-\(UUID())")
    let store = SessionStore(service: "discovery-keyboard-\(UUID())", protection: .unprotectedForTests)
    defer {
      try? store.delete()
      try? FileManager.default.removeItem(at: directory)
    }
    let fake = FakeContextProvider(
      application: ApplicationContext(bundleID: "net.imput.helium", name: "Helium"), hostname: nil)
    fake.delay = .milliseconds(100)
    let model = AppModel(
      config: AppModel.configuration(environment: ["ENTE_MENUBAR_API_ORIGIN": museum.fixture.endpoint]),
      sessionStore: store, cacheStore: CacheStore(url: directory.appending(path: "cache.bin")),
      contextProvider: fake)
    await model.launch()
    model.setVisible(true)
    model.setEmail(museum.fixture.email)
    await model.submit(password: museum.fixture.password)
    #expect(model.selectedRowID == .websiteSetup)
    model.moveSelection(1)
    #expect(model.rows.first { $0.id == model.selectedRowID }?.code?.issuer == "Legacy")
    model.moveSelection(-1)
    model.activateSelection()
    #expect(model.websiteSuggestions == true)
    #expect(await eventually { model.context?.application.bundleID == "net.imput.helium" })
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.context?.hostname == nil)
    #expect(model.rows.contains { $0.id == .websiteSetup } == false)
    if case .ready(let session) = model.phase {
      let codes = (1...20).map { index in
        discoveryCode("id-\(index)", index <= 5 ? "GitHub" : "Service \(index)", "account \(index)")
      }
      let state = VaultState(codes: codes, lastSuccessfulSync: nil, syncStatus: .idle, unreadableCount: 0)
      let preview = AppModel(snapshotPhase: .ready(VaultSession(vault: session.vault, state: state)),
        context: ForegroundContext(application: fake.application!, hostname: "github.com"))
      preview.moveSelection(3)
      #expect(preview.selectedRowID == .more)
      preview.activateSelection()
      #expect(preview.search == "github.com")
      #expect(preview.rows.compactMap(\.code).map(\.id) == ["id-1", "id-2", "id-3", "id-4", "id-5"])
      preview.search = ""
      preview.moveSelection(100)
      #expect(preview.selectedRowID == .showAll)
      preview.activateSelection()
      #expect(preview.selectedRowID == .code(.all, "id-4"))
      #expect(preview.rows.filter { if case .code(.all, _) = $0 { true } else { false } }.count == 17)
      preview.moveSelection(1)
      #expect(preview.selectedRowID == .code(.all, "id-5"))
    } else {
      Issue.record("Expected a ready vault for the keyboard fixture")
    }
    fake.hostname = "github.com"
    model.setVisible(false)
    model.setVisible(true)
    model.setVisible(false)
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.context?.hostname == nil)
    await model.signOut()
  }

  @Test func openingWaitsForHostnameUntilItLandsTheCapPassesOrThePanelCloses() async throws {
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let directory = FileManager.default.temporaryDirectory.appending(path: "discovery-wait-\(UUID())")
    let store = SessionStore(service: "discovery-wait-\(UUID())", protection: .unprotectedForTests)
    let preferences = try #require(UserDefaults(suiteName: "discovery-wait-\(UUID())"))
    defer {
      try? store.delete()
      try? FileManager.default.removeItem(at: directory)
    }
    let helium = ApplicationContext(bundleID: "net.imput.helium", name: "Helium")
    let fake = FakeContextProvider(application: helium, hostname: "github.com")
    let model = AppModel(
      config: AppModel.configuration(environment: ["ENTE_MENUBAR_API_ORIGIN": museum.fixture.endpoint]),
      sessionStore: store, cacheStore: CacheStore(url: directory.appending(path: "cache.bin")),
      contextProvider: fake, preferences: preferences)
    await model.launch()
    model.setEmail(museum.fixture.email)
    await model.submit(password: museum.fixture.password)
    model.setWebsiteSuggestions(true)
    let clock = ContinuousClock()

    fake.delay = .milliseconds(30)
    model.setVisible(true)
    var started = clock.now
    await model.contextSettled(within: .seconds(5))
    #expect(clock.now - started < .seconds(2))
    #expect(model.context == ForegroundContext(application: helium, hostname: "github.com", websiteAccess: .allowed))
    model.setVisible(false)

    fake.delay = .milliseconds(600)
    model.setVisible(true)
    await model.contextSettled(within: .milliseconds(50))
    #expect(model.context == ForegroundContext(application: helium))
    #expect(await eventually { model.context?.hostname == "github.com" })
    model.setVisible(false)

    model.setVisible(true)
    started = clock.now
    let waiting = Task { await model.contextSettled(within: .seconds(5)) }
    try await Task.sleep(for: .milliseconds(20))
    model.setVisible(false)
    await waiting.value
    #expect(clock.now - started < .seconds(2))

    let terminal = ApplicationContext(bundleID: "com.apple.Terminal", name: "Terminal")
    fake.application = terminal
    model.setVisible(true)
    started = clock.now
    await model.contextSettled(within: .seconds(5))
    #expect(clock.now - started < .milliseconds(100))
    #expect(model.context == ForegroundContext(application: terminal))
    await model.signOut()
  }
}
