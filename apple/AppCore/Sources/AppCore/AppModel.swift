import AppKit
import EnteBridge
import Foundation
import Observation

public enum Phase {
  case launching
  case signedOut(SignIn)
  case ready(VaultState)
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

  private let config: Config
  private let sessionStore: SessionStore
  private let cacheStore: CacheStore
  private let pasteboard: NSPasteboard
  private let now: () -> Date
  private var login: LoginFlow?
  private var vault: Vault?
  private var generation = 0
  private var copiedTask: Task<Void, Never>?

  public init(
    config: Config = AppModel.configuration(), sessionStore: SessionStore = SessionStore(),
    cacheStore: CacheStore = CacheStore(), pasteboard: NSPasteboard = .general,
    now: @escaping () -> Date = Date.init
  ) {
    self.config = config
    self.sessionStore = sessionStore
    self.cacheStore = cacheStore
    self.pasteboard = pasteboard
    self.now = now
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
      sessionStore: SessionStore(service: "dev.entemenubar.EnteMenubar" + (profile.map { ".\($0)" } ?? "")),
      cacheStore: CacheStore(url: URL.applicationSupportDirectory.appending(path: "\(folder)/cache.bin")))
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
      guard let session = try sessionStore.load() else {
        phase = .signedOut(SignIn())
        return
      }
      let vault = try Vault(config: config, session: session, cache: try? cacheStore.load())
      let restored = (try? vault.codes(nowUnixMs: timestamp))?.isEmpty == false
      try open(vault, lastSync: restored ? cacheStore.modifiedAt : nil)
      Task { await sync() }
    } catch {
      phase = .signedOut(SignIn(error: message(error)))
    }
  }

  public func setEmail(_ email: String) {
    guard case .signedOut(var signIn) = phase, !signIn.busy else { return }
    signIn.email = email
    phase = .signedOut(signIn)
  }

  public func submit(_ value: String = "") async {
    guard case .signedOut(var signIn) = phase, !signIn.busy else { return }
    let epoch = generation
    signIn.busy = true
    signIn.error = nil
    phase = .signedOut(signIn)
    do {
      let step: LoginStep
      switch signIn.step {
      case .email:
        let flow = try LoginFlow(config: config)
        login = flow
        step = try await flow.prepare(email: signIn.email)
      case .password:
        guard let login else { return }
        step = try await login.submitPassword(password: value)
      case .emailCode, .authenticatorCode:
        guard let login else { return }
        step = try await login.submitCode(code: value)
      case .passkeyUnsupported:
        return
      }
      guard epoch == generation else { return }
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
      guard epoch == generation else { return }
      signIn.busy = false
      signIn.error = message(error)
      phase = .signedOut(signIn)
    }
  }

  public func resendCode() async {
    guard case .signedOut(var signIn) = phase, signIn.step == .emailCode, !signIn.busy,
      let login
    else { return }
    let epoch = generation
    signIn.busy = true
    signIn.error = nil
    phase = .signedOut(signIn)
    do { try await login.resendCode() } catch { signIn.error = message(error) }
    guard epoch == generation else { return }
    signIn.busy = false
    phase = .signedOut(signIn)
  }

  public func signOut(message: String? = nil) {
    generation += 1
    vault = nil
    login = nil
    search = ""
    selectedID = nil
    copiedTask?.cancel()
    copiedID = nil
    var errors: [String] = []
    do { try sessionStore.delete() } catch { errors.append(self.message(error)) }
    do { try cacheStore.delete() } catch {
      errors.append("Unable to remove the cached vault. \(error.localizedDescription)")
    }
    phase = .signedOut(SignIn(error: errors.isEmpty ? message : errors.joined(separator: " ")))
  }

  public func sync() async {
    guard case .ready(var state) = phase, state.syncStatus != .syncing, let vault else { return }
    let previousStatus = state.syncStatus
    let epoch = generation
    state.syncStatus = .syncing
    phase = .ready(state)
    do {
      let summary = try await vault.sync()
      guard epoch == generation else { return }
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
    } catch {
      guard epoch == generation else { return }
      switch error as? BridgeError {
      case .Unauthorized?:
        signOut(message: message(error))
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
    phase = .ready(state)
    preserveSelection()
  }

  public func setVisible(_ visible: Bool) {
    guard self.visible != visible else { return }
    self.visible = visible
    if visible { refreshCodes() }
  }

  public func refreshCodes() {
    guard visible, case .ready(var state) = phase, let vault else { return }
    do {
      state.codes = try vault.codes(nowUnixMs: timestamp)
      phase = .ready(state)
      preserveSelection()
    } catch {
      state.syncStatus = .failed(message(error))
      phase = .ready(state)
    }
  }

  public var filteredCodes: [CodeView] {
    guard case .ready(let state) = phase else { return [] }
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return state.codes.filter {
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
    guard let id = id ?? selectedID, let vault,
      let code = try? vault.codes(nowUnixMs: timestamp).first(where: { $0.id == id }),
      code.kind != .hotp, !code.display.trashed
    else { return }
    selectedID = id
    pasteboard.clearContents()
    guard pasteboard.setString(code.current, forType: .string) else { return }
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
    self.vault = vault
    phase = .ready(
      VaultState(
        codes: codes, lastSuccessfulSync: lastSync, syncStatus: .idle,
        unreadableCount: vault.unreadableCount()))
    selectFirst()
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
