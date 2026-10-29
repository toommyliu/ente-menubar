import AppKit
import EnteBridge
import Foundation
import Testing

@testable import AppCore

@Suite @MainActor
struct AppModelTests {
  @Test func loginCacheCopySignOutAndOfflineRelaunch() async throws {
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let service = "dev.entemenubar.EnteMenubar.tests.\(UUID())"
    let sessionStore = SessionStore(service: service)
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
      pasteboard: pasteboard, now: { instant })
    await model.launch()
    guard case .signedOut(let initial) = model.phase else {
      Issue.record("Expected signed out")
      return
    }
    #expect(initial.step == .email)
    model.setEmail(museum.fixture.email)
    await model.submit()
    guard case .signedOut(let prepared) = model.phase else {
      Issue.record("Expected password step")
      return
    }
    #expect(prepared.step == .password)
    await model.submit(museum.fixture.password)
    guard case .ready(let ready) = model.phase else {
      Issue.record("Expected ready after password")
      return
    }
    #expect(ready.syncStatus == .idle)
    #expect(
      ready.codes.sorted { $0.issuer < $1.issuer }.map(\.current) == [
        "", "755224", "287082", "46119246", "PV9M4", "287082",
      ])
    #expect(model.filteredCodes.map(\.issuer) == ["Counter", "Legacy", "RFC", "SHA256", "Steam"])
    #expect(model.orderedCodes.map(\.issuer) == ["Legacy", "RFC", "Counter", "SHA256", "Steam"])
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
    try await Task.sleep(for: .milliseconds(1300))
    #expect(model.copiedID == nil)
    model.search = "no such issuer"
    #expect(model.filteredCodes.isEmpty)
    model.search = "alice"
    #expect(model.filteredCodes.count == 5)
    model.search = ""
    model.moveSelection(1)
    #expect(model.selectedID == ready.codes.first { $0.issuer == "RFC" }?.id)
    let savedSession = try #require(try sessionStore.load())
    let savedCache = try #require(try cacheStore.load())
    model.signOut()
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
      pasteboard: pasteboard, now: { instant })
    await relaunched.launch()
    guard case .ready(let cached) = relaunched.phase else {
      Issue.record("Expected immediate cached codes")
      return
    }
    #expect(cached.codes == ready.codes)
    for _ in 0..<200 {
      if case .ready(let state) = relaunched.phase, case .offline = state.syncStatus { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard case .ready(let offline) = relaunched.phase, case .offline = offline.syncStatus else {
      Issue.record("Expected offline with cached codes after server stops")
      return
    }
    #expect(offline.codes == ready.codes)
    #expect(offline.lastSuccessfulSync != nil)
    relaunched.signOut()
    #expect(try sessionStore.load() == nil)
    #expect(try cacheStore.load() == nil)
  }

  @Test func wrongPasswordStaysAtPasswordWithInlineError() async throws {
    let museum = try LocalMuseum()
    defer { museum.stop() }
    let store = SessionStore(service: "dev.entemenubar.EnteMenubar.tests.\(UUID())")
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

@MainActor private final class LocalMuseum {
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
