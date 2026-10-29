import AppKit
import EnteBridge
import Foundation
import Testing

@testable import AppCore

@Suite @MainActor
struct AppModelTests {
  @Test func protectedSessionUsesDataProtectionKeychainWithUserPresence() throws {
    let request = try SessionStore(service: "test", protection: .userPresence).addRequest(Data([1]))
    #expect(request[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(request[kSecAttrAccessControl as String] != nil)
    #expect(request[kSecAttrAccessible as String] == nil)
    let unprotected = try SessionStore(service: "test", protection: .unprotectedForTests)
      .addRequest(Data([1]))
    #expect(unprotected[kSecUseDataProtectionKeychain as String] == nil)
    #expect(unprotected[kSecAttrAccessControl as String] == nil)
  }

  @Test func loginCacheCopySignOutAndOfflineRelaunch() async throws {
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let service = "dev.entemenubar.EnteMenubar.tests.\(UUID())"
    let sessionStore = SessionStore(service: service, protection: .unprotectedForTests)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "EnteMenubar-tests-\(UUID())")
    let cacheStore = CacheStore(url: directory.appending(path: "cache.bin"))
    defer {
      try? sessionStore.delete()
      try? FileManager.default.removeItem(at: directory)
    }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("EnteMenubar-tests-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    var instant = Date(timeIntervalSince1970: 59)
    let config = AppModel.configuration(environment: [
      "ENTE_MENUBAR_API_ORIGIN": museum.fixture.endpoint
    ])
    let model = AppModel(
      config: config, sessionStore: sessionStore, cacheStore: cacheStore,
      pasteboard: pasteboard, contextProvider: FakeContextProvider(), now: { instant },
      clipboardLifetime: .milliseconds(100), lockDelay: .milliseconds(100))
    await model.launch()
    guard case .signedOut(let initial) = model.phase else {
      Issue.record("Expected signed out")
      return
    }
    #expect(initial.step == .email)
    model.setVisible(true)
    model.setEmail(museum.fixture.email)
    await model.submit()
    guard case .signedOut(let prepared) = model.phase else {
      Issue.record("Expected password step")
      return
    }
    #expect(prepared.step == .password)
    await model.submit(museum.fixture.password)
    guard case .ready(let session) = model.phase else {
      Issue.record("Expected ready after password")
      return
    }
    let ready = session.state
    #expect(ready.syncStatus == .idle)
    #expect(
      ready.codes.sorted { $0.issuer < $1.issuer }.map(\.current) == [
        "", "755224", "287082", "46119246", "PV9M4", "287082",
      ])
    #expect(model.filteredCodes.map(\.issuer) == ["Counter", "Legacy", "RFC", "SHA256", "Steam"])
    #expect(model.rows.compactMap(\.code).map(\.issuer)
      == ["Legacy", "RFC", "Counter", "SHA256", "Steam"])
    #expect(ready.lastSuccessfulSync == Date(timeIntervalSince1970: 59))
    #expect(try sessionStore.load()?.isEmpty == false)
    #expect(try cacheStore.load()?.isEmpty == false)
    let attributes = try FileManager.default.attributesOfItem(atPath: cacheStore.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    model.search = "rFc"
    #expect(model.filteredCodes.map(\.issuer) == ["RFC"])
    instant = Date(timeIntervalSince1970: 60)
    model.copy()
    #expect(pasteboard.string(forType: .string) == "359152")
    #expect(model.copiedID == model.filteredCodes.first?.id)
    #expect(
      pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        == true)
    #expect(
      pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        == true)
    #expect(await eventually { pasteboard.string(forType: .string) == nil })
    model.copy()
    #expect(pasteboard.string(forType: .string) == "359152")
    pasteboard.clearContents()
    pasteboard.setString("359152", forType: .string)
    try await Task.sleep(for: .milliseconds(400))
    #expect(pasteboard.string(forType: .string) == "359152")
    #expect(await eventually { model.copiedID == nil })
    model.search = "no such issuer"
    #expect(model.filteredCodes.isEmpty)
    model.search = "alice"
    #expect(model.filteredCodes.count == 5)
    model.search = ""
    model.moveSelection(1)
    #expect(model.selectedID == ready.codes.first { $0.issuer == "RFC" }?.id)
    let savedSession = try #require(try sessionStore.load())
    let savedCache = try #require(try cacheStore.load())
    await model.signOut()
    #expect(try sessionStore.load() == nil)
    #expect(try cacheStore.load() == nil)
    guard case .signedOut(let signedOut) = model.phase else {
      Issue.record("Expected signed out")
      return
    }
    #expect(signedOut.step == .email)
    #expect(signedOut.error == nil)
    try sessionStore.save(savedSession)
    try cacheStore.save(savedCache)
    museum.stop()
    instant = Date(timeIntervalSince1970: 59)
    let relaunched = AppModel(
      config: config, sessionStore: sessionStore, cacheStore: cacheStore,
      pasteboard: pasteboard, contextProvider: FakeContextProvider(), now: { instant }, lockDelay: .milliseconds(100))
    await relaunched.launch()
    guard case .locked = relaunched.phase else {
      Issue.record("Expected locked on launch")
      return
    }
    #expect(relaunched.filteredCodes.isEmpty)
    relaunched.setVisible(true)
    await relaunched.unlock()
    guard case .ready(let cached) = relaunched.phase else {
      Issue.record("Expected cached codes before network sync")
      return
    }
    #expect(cached.state.codes == ready.codes)
    for _ in 0..<200 {
      if case .ready(let state) = relaunched.phase, case .offline = state.state.syncStatus { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard case .ready(let offline) = relaunched.phase, case .offline = offline.state.syncStatus
    else {
      Issue.record("Expected offline with cached codes after server stops")
      return
    }
    #expect(offline.state.codes == ready.codes)
    #expect(offline.state.lastSuccessfulSync != nil)
    relaunched.setVisible(true)
    relaunched.setVisible(false)
    _ = await eventually {
      if case .locked = relaunched.phase { return true }
      return false
    }
    guard case .locked = relaunched.phase else {
      Issue.record("Expected automatic lock after popover closes")
      return
    }
    #expect(relaunched.filteredCodes.isEmpty)
    #expect(relaunched.selectedID == nil)
    relaunched.copy(id: ready.codes.first { $0.issuer == "RFC" }?.id)
    #expect(pasteboard.string(forType: .string) == "359152")
    relaunched.setVisible(true)
    for _ in 0..<200 {
      if case .ready = relaunched.phase { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    guard case .ready(let reopened) = relaunched.phase else {
      Issue.record("Expected opening the locked popover to unlock")
      return
    }
    #expect(reopened.state.codes == ready.codes)
    let observer = LockObserver(model: relaunched)
    defer { withExtendedLifetime(observer) {} }
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    for _ in 0..<20 {
      if case .locked = relaunched.phase { break }
      await Task.yield()
    }
    guard case .locked = relaunched.phase else {
      Issue.record("Expected system sleep notification to lock")
      return
    }
    #expect(relaunched.filteredCodes.isEmpty)
    await relaunched.unlock()
    await relaunched.sync()
    await relaunched.signOut()
    #expect(try sessionStore.load() == nil)
    #expect(try cacheStore.load() == nil)
  }

  @Test func revokedSessionExpiresAfterUnlock() async throws {
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let store = SessionStore(
      service: "dev.entemenubar.EnteMenubar.tests.\(UUID())", protection: .unprotectedForTests)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "EnteMenubar-tests-\(UUID())")
    let cache = CacheStore(url: directory.appending(path: "cache.bin"))
    defer {
      try? store.delete()
      try? FileManager.default.removeItem(at: directory)
    }
    let config = AppModel.configuration(environment: [
      "ENTE_MENUBAR_API_ORIGIN": museum.fixture.endpoint
    ])
    let model = AppModel(config: config, sessionStore: store, cacheStore: cache, contextProvider: FakeContextProvider())
    await model.launch()
    model.setEmail(museum.fixture.email)
    await model.submit()
    await model.submit(museum.fixture.password)
    #expect(model.filteredCodes.map(\.issuer) == ["Counter", "Legacy", "RFC", "SHA256", "Steam"])
    let savedSession = try #require(try store.load())
    weak let openedVault: Vault? = {
      guard case .ready(let session) = model.phase else { return nil }
      return session.vault
    }()
    #expect(openedVault != nil)
    model.lock()
    #expect(openedVault == nil)
    #expect(model.filteredCodes.isEmpty)
    await model.unlock()
    await model.sync()
    await model.signOut()
    #expect(try store.load() == nil)
    try store.save(savedSession)
    let restored = AppModel(config: config, sessionStore: store, cacheStore: cache, contextProvider: FakeContextProvider())
    await restored.launch()
    guard case .locked = restored.phase else {
      Issue.record("Expected saved session to start locked")
      return
    }
    await restored.unlock()
    for _ in 0..<200 {
      if case .signedOut = restored.phase { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard case .signedOut(let expired) = restored.phase else {
      Issue.record("Expected revoked token to sign out")
      return
    }
    #expect(expired.error == "Your session expired. Sign in again.")
    #expect(restored.filteredCodes.isEmpty)
    #expect(try store.load() == nil)
  }

  @Test func wrongPasswordStaysAtPasswordWithInlineError() async throws {
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let store = SessionStore(
      service: "dev.entemenubar.EnteMenubar.tests.\(UUID())", protection: .unprotectedForTests)
    defer { try? store.delete() }
    let model = AppModel(
      config: AppModel.configuration(environment: [
        "ENTE_MENUBAR_API_ORIGIN": museum.fixture.endpoint
      ]),
      sessionStore: store)
    await model.launch()
    model.setEmail(museum.fixture.email)
    await model.submit()
    await model.submit("wrong password")
    guard case .signedOut(let signIn) = model.phase else {
      Issue.record("Expected sign-in error")
      return
    }
    #expect(signIn.step == .password)
    #expect(signIn.error == "Incorrect password. Try again.")
    #expect(!signIn.busy)
    #expect(try store.load() == nil)
  }
}

@MainActor final class LocalMuseum {
  struct Fixture: Decodable {
    let endpoint: String
    let email: String
    let password: String
  }

  let process: Process
  let fixture: Fixture
  private let output: Pipe
  private let errors: FileHandle

  init() throws {
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let process = Process()
    process.executableURL = repo.appending(path: "rust/target/debug/ente-devserver")
    process.currentDirectoryURL = repo
    let output = Pipe()
    let logURL = repo.appending(path: ".build/verification/model-museum-\(UUID()).log")
    _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let errors = try FileHandle(forWritingTo: logURL)
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    var line = Data()
    while true {
      let byte = output.fileHandleForReading.readData(ofLength: 1)
      if byte.isEmpty || byte == Data([10]) { break }
      line.append(byte)
    }
    do { fixture = try JSONDecoder().decode(Fixture.self, from: line) } catch {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      try? errors.close()
      throw error
    }
    self.process = process
    self.output = output
    self.errors = errors
  }

  func stop() {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    try? output.fileHandleForReading.close()
    try? errors.close()
  }
}

@MainActor func eventually(
  within timeout: Duration = .seconds(3), _ condition: () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return condition()
}
