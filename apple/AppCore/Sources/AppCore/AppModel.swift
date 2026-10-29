import AppKit
import EnteBridge
import Foundation
import Observation

public enum Phase {
  case launching
  case signedOut(SignIn)
  case locked
  case unlocking(UUID)
  case ready(VaultSession)
}

public struct SignIn {
  public enum Step: Equatable {
    case email, password, emailCode, authenticatorCode, passkeyUnsupported
  }

  public var email = ""
  public var step: Step = .email
  public var busy = false
  public var error: String?
}

public struct VaultState {
  public enum SyncStatus: Equatable {
    case idle, syncing
    case offline(since: Date)
    case failed(String)
  }

  public var codes: [CodeView]
  public var lastSuccessfulSync: Date?
  public var syncStatus: SyncStatus
  public var unreadableCount: UInt64

  func filteredCodes(search: String) -> [CodeView] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return codes.filter {
      !$0.display.trashed
        && (query.isEmpty || $0.issuer.localizedCaseInsensitiveContains(query)
          || $0.account.localizedCaseInsensitiveContains(query))
    }.sorted {
      let issuer = $0.issuer.localizedCaseInsensitiveCompare($1.issuer)
      if issuer != .orderedSame { return issuer == .orderedAscending }
      let account = $0.account.localizedCaseInsensitiveCompare($1.account)
      return account == .orderedSame ? $0.id < $1.id : account == .orderedAscending
    }
  }

}

public struct VaultSession {
  public let vault: Vault
  public var state: VaultState
}

@MainActor @Observable
public final class AppModel {
  public private(set) var phase: Phase = .launching
  public var search = "" {
    didSet { selectFirst() }
  }
  public private(set) var selectedID: String?
  public private(set) var copiedID: String?
  public private(set) var visible = false
  public private(set) var unlockError: String?

  private let config: Config
  private let sessionStore: SessionStore
  private let cacheStore: CacheStore
  private let pasteboard: NSPasteboard
  private let now: () -> Date
  private var login: LoginFlow?
  private var copiedTask: Task<Void, Never>?
  private var clipboardTask: Task<Void, Never>?
  private var lockTask: Task<Void, Never>?
  private let clipboardLifetime: Duration
  private let lockDelay: Duration

  public init(
    config: Config = AppModel.configuration(),
    sessionStore: SessionStore = SessionStore(protection: .userPresence),
    cacheStore: CacheStore = CacheStore(), pasteboard: NSPasteboard = .general,
    now: @escaping () -> Date = Date.init,
    clipboardLifetime: Duration = .seconds(30), lockDelay: Duration = .seconds(15 * 60)
  ) {
    self.config = config
    self.sessionStore = sessionStore
    self.cacheStore = cacheStore
    self.pasteboard = pasteboard
    self.now = now
    self.clipboardLifetime = clipboardLifetime
    self.lockDelay = lockDelay
  }

  convenience init(snapshotPhase: Phase, search: String = "", copiedID: String? = nil) {
    self.init(
      config: Self.configuration(environment: ["ENTE_MENUBAR_API_ORIGIN": "http://127.0.0.1:1"]))
    self.phase = snapshotPhase
    self.search = search
    self.copiedID = copiedID
    selectFirst()
  }

  public static func live(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> AppModel {
    let profile = environment["ENTE_MENUBAR_PROFILE"]
    let folder = profile.map { "EnteMenubar/\($0)" } ?? "EnteMenubar"
    return AppModel(
      config: configuration(environment: environment),
      sessionStore: SessionStore(
        service: "dev.entemenubar.EnteMenubar" + (profile.map { ".\($0)" } ?? ""),
        protection: .userPresence),
      cacheStore: CacheStore(
        url: URL.applicationSupportDirectory.appending(path: "\(folder)/cache.bin")))
  }

  public static func configuration(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Config {
    Config(
      apiOrigin: environment["ENTE_MENUBAR_API_ORIGIN"] ?? "https://api.ente.com",
      clientPackage: "io.ente.auth.menubar", userAgent: "EnteMenubar/0.1")
  }

  public func run() async {
    await launch()
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(60)) } catch { return }
      if visible { await sync() }
    }
  }

  public func launch() async {
    guard case .launching = phase else { return }
    do {
      phase = try sessionStore.containsSession() ? .locked : .signedOut(SignIn())
      if visible, case .locked = phase { await unlock() }
    } catch {
      phase = .signedOut(SignIn(error: message(error)))
    }
  }

  public func unlock() async {
    guard case .locked = phase else { return }
    let attempt = UUID()
    phase = .unlocking(attempt)
    unlockError = nil
    do {
      let store = sessionStore
      let session = try await Task.detached { try store.load() }.value
      guard case .unlocking(let current) = phase, current == attempt else { return }
      guard let session else {
        phase = .signedOut(SignIn())
        return
      }
      let vault = try Vault(config: config, session: session, cache: try? cacheStore.load())
      try open(vault, lastSync: cacheStore.modifiedAt)
      Task { await sync() }
    } catch {
      guard case .unlocking(let current) = phase, current == attempt else { return }
      phase = .locked
      if (error as? StorageError)?.isCancelled != true { unlockError = message(error) }
    }
  }

  public func lock() {
    switch phase {
    case .ready, .unlocking:
      phase = .locked
      resetSelection()
      lockTask?.cancel()
    case .launching, .signedOut, .locked:
      break
    }
  }

  public func setEmail(_ email: String) {
    guard case .signedOut(var signIn) = phase, !signIn.busy else { return }
    signIn.email = email
    phase = .signedOut(signIn)
  }

  public func submit(_ value: String = "") async {
    guard case .signedOut(var signIn) = phase, !signIn.busy else { return }
    signIn.busy = true
    signIn.error = nil
    phase = .signedOut(signIn)
    let flow: LoginFlow
    do {
      if signIn.step == .email {
        flow = try LoginFlow(config: config)
        login = flow
      } else if let login {
        flow = login
      } else {
        return
      }
    } catch {
      signIn.busy = false
      signIn.error = message(error)
      phase = .signedOut(signIn)
      return
    }
    do {
      let step: LoginStep
      switch signIn.step {
      case .email: step = try await flow.prepare(email: signIn.email)
      case .password: step = try await flow.submitPassword(password: value)
      case .emailCode, .authenticatorCode: step = try await flow.submitCode(code: value)
      case .passkeyUnsupported: return
      }
      guard login === flow else { return }
      switch step {
      case .emailCode: signIn.step = .emailCode
      case .password: signIn.step = .password
      case .authenticatorCode: signIn.step = .authenticatorCode
      case .passkeyUnsupported: signIn.step = .passkeyUnsupported
      case .complete(let session):
        let vault = try Vault(config: config, session: session, cache: nil)
        try sessionStore.save(session)
        try open(vault, lastSync: nil)
        login = nil
        await sync()
        return
      }
      signIn.busy = false
      phase = .signedOut(signIn)
    } catch {
      guard login === flow else { return }
      signIn.busy = false
      signIn.error = message(error)
      phase = .signedOut(signIn)
    }
  }

  public func resendCode() async {
    guard case .signedOut(var signIn) = phase, signIn.step == .emailCode, !signIn.busy,
      let login
    else { return }
    signIn.busy = true
    signIn.error = nil
    phase = .signedOut(signIn)
    do { try await login.resendCode() } catch { signIn.error = message(error) }
    guard self.login === login else { return }
    signIn.busy = false
    phase = .signedOut(signIn)
  }

  public func signOut() async {
    let vault: Vault?
    if case .ready(let session) = phase { vault = session.vault } else { vault = nil }
    clearSession()
    try? await vault?.logout()
  }

  private func clearSession(message: String? = nil) {
    login = nil
    lockTask?.cancel()
    resetSelection()
    unlockError = nil
    var errors: [String] = []
    do { try sessionStore.delete() } catch { errors.append(self.message(error)) }
    do { try cacheStore.delete() } catch {
      errors.append("Unable to remove the cached vault. \(error.localizedDescription)")
    }
    phase = .signedOut(SignIn(error: errors.isEmpty ? message : errors.joined(separator: " ")))
  }

  private func resetSelection() {
    search = ""
    selectedID = nil
    copiedTask?.cancel()
    copiedID = nil
  }

  private func beginSync() -> (Vault, VaultState.SyncStatus)? {
    guard case .ready(var session) = phase, session.state.syncStatus != .syncing else { return nil }
    let previousStatus = session.state.syncStatus
    session.state.syncStatus = .syncing
    phase = .ready(session)
    return (session.vault, previousStatus)
  }

  public func sync() async {
    guard let (vault, previousStatus) = beginSync() else { return }
    let result: Result<SyncSummary, Error>
    do { result = .success(try await vault.sync()) } catch { result = .failure(error) }
    guard case .ready(var session) = phase, session.vault === vault else { return }
    var state = session.state
    switch result {
    case .success(let summary):
      do {
        state.codes = try vault.codes(nowUnixMs: timestamp)
        let changed =
          summary.upserted + summary.deleted > 0 || summary.unreadable != state.unreadableCount
          || cacheStore.modifiedAt == nil
        state.unreadableCount = summary.unreadable
        state.lastSuccessfulSync = now()
        state.syncStatus = .idle
        do {
          if changed { try cacheStore.save(vault.exportCache()) } else { try cacheStore.touch() }
        } catch {
          state.syncStatus = .failed(
            "Unable to save the offline cache. \(error.localizedDescription)")
        }
      } catch { state.syncStatus = .failed(message(error)) }
    case .failure(let error):
      switch error as? BridgeError {
      case .Unauthorized?:
        clearSession(message: message(error))
        return
      case .Network?:
        if case .offline(let since) = previousStatus {
          state.syncStatus = .offline(since: since)
        } else {
          state.syncStatus = .offline(since: now())
        }
      default:
        state.syncStatus = .failed(message(error))
      }
      state.codes = (try? vault.codes(nowUnixMs: timestamp)) ?? state.codes
    }
    session.state = state
    phase = .ready(session)
    preserveSelection()
  }

  public func setVisible(_ visible: Bool) {
    guard self.visible != visible else { return }
    self.visible = visible
    lockTask?.cancel()
    if visible {
      refreshCodes()
      if case .locked = phase { Task { await unlock() } }
    } else {
      scheduleLock()
    }
  }

  private func scheduleLock() {
    lockTask?.cancel()
    lockTask = Task { [weak self, lockDelay] in
      do { try await Task.sleep(for: lockDelay) } catch { return }
      self?.lock()
    }
  }

  public func refreshCodes() {
    guard visible, case .ready(var session) = phase else { return }
    let vault = session.vault
    var state = session.state
    do {
      state.codes = try vault.codes(nowUnixMs: timestamp)
      session.state = state
      phase = .ready(session)
      preserveSelection()
    } catch {
      state.syncStatus = .failed(message(error))
      session.state = state
      phase = .ready(session)
    }
  }

  public var filteredCodes: [CodeView] {
    guard case .ready(let session) = phase else { return [] }
    return session.state.filteredCodes(search: search)
  }

  public var orderedCodes: [CodeView] {
    let codes = filteredCodes
    return codes.filter(\.display.pinned) + codes.filter { !$0.display.pinned }
  }

  public func moveSelection(_ offset: Int) {
    let codes = orderedCodes
    guard !codes.isEmpty else { return }
    let index = codes.firstIndex { $0.id == selectedID } ?? 0
    selectedID = codes[min(max(index + offset, 0), codes.count - 1)].id
  }

  public func copy(id: String? = nil) {
    guard case .ready(let session) = phase, let id = id ?? selectedID,
      let code = try? session.vault.codes(nowUnixMs: timestamp).first(where: { $0.id == id }),
      code.kind != .hotp, !code.display.trashed
    else { return }
    selectedID = id
    let item = NSPasteboardItem()
    item.setString(code.current, forType: .string)
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { return }
    let changeCount = pasteboard.changeCount
    clipboardTask?.cancel()
    clipboardTask = Task { [pasteboard, clipboardLifetime] in
      do { try await Task.sleep(for: clipboardLifetime) } catch { return }
      if pasteboard.changeCount == changeCount { pasteboard.clearContents() }
    }
    copiedID = id
    copiedTask?.cancel()
    copiedTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
      self?.copiedID = nil
    }
  }

  private var timestamp: Int64 { Int64(now().timeIntervalSince1970 * 1000) }

  private func open(_ vault: Vault, lastSync: Date?) throws {
    let codes = try vault.codes(nowUnixMs: timestamp)
    phase = .ready(
      VaultSession(
        vault: vault,
        state: VaultState(
          codes: codes, lastSuccessfulSync: lastSync, syncStatus: .idle,
          unreadableCount: vault.unreadableCount())))
    selectFirst()
    if !visible { scheduleLock() }
  }

  private func selectFirst() { selectedID = orderedCodes.first?.id }

  private func preserveSelection() {
    if !orderedCodes.contains(where: { $0.id == selectedID }) { selectFirst() }
  }

  private func message(_ error: Error) -> String {
    guard let error = error as? BridgeError else { return error.localizedDescription }
    switch error {
    case .Network: return "Unable to connect. Check your connection and try again."
    case .InvalidCredentials: return "Incorrect password. Try again."
    case .InvalidCode: return "Incorrect or expired code. Try again."
    case .Unauthorized: return "Your session expired. Sign in again."
    case .RateLimited: return "Too many attempts. Wait a moment and try again."
    case .Unsupported(let message), .Internal(let message): return message
    }
  }
}
