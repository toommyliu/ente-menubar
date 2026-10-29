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
    case credentials, emailCode, authenticatorCode, passkeyUnsupported
  }

  public var email = ""
  public var step: Step = .credentials
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

public struct VaultSession {
  public let vault: Vault
  public var state: VaultState
}

enum ShortcutEditor: Equatable {
  case browsing
  case recording(ShortcutAction, problem: ShortcutProblem?)
}

@MainActor @Observable
public final class AppModel {
  public private(set) var phase: Phase = .launching
  public var search = "" {
    didSet {
      contextSearch = false
      selectFirst()
    }
  }
  private(set) var selectedRowID: DiscoveryRowID?
  public var selectedID: String? {
    if case .code(_, let id) = selectedRowID { return id }
    return nil
  }
  public private(set) var copiedID: String?
  public private(set) var copiedNext = false
  private var frozenUsage: UsageHistory?
  private var layoutUsage: UsageHistory { frozenUsage ?? usage }
  public private(set) var visible = false
  public private(set) var unlockError: String?
  public private(set) var showSuggestions: Bool
  private(set) var keymap: Keymap
  private(set) var shortcutEditor: ShortcutEditor?
  private(set) var unavailableGlobalShortcut: KeyCombo?
  public private(set) var settingsError: String?
  @ObservationIgnored public var onOpen: (@MainActor () -> Void)?
  @ObservationIgnored public var onClose: (@MainActor () -> Void)?
  @ObservationIgnored public var onSystemPromptFinished: (@MainActor () -> Void)?
  public private(set) var loginItemStatus: LoginItemStatus
  public private(set) var codeSampleDate: Date
  private let loginItem: any LoginItemManaging
  @ObservationIgnored private var globalRegistration: (@MainActor (KeyCombo?) throws -> Void)?
  public private(set) var hideCodes: Bool
  public private(set) var optionHeld = false
  public var codesHidden: Bool { hideCodes && !optionHeld }
  public private(set) var websiteSuggestions: Bool
  private var requestingWebsiteAccess = false
  public var awaitingSystemPrompt: Bool {
    if case .unlocking = phase { return true }
    return requestingWebsiteAccess
  }
  private(set) var context: ForegroundContext?
  private var openedFrom: ApplicationContext?
  private(set) var usage: UsageHistory
  private(set) var usageError: String?
  private var allExpanded = false
  private var contextSearch = false
  private var snapshotState: VaultState?

  private let config: Config
  private let sessionStore: SessionStore
  private let cacheStore: CacheStore
  private let pasteboard: NSPasteboard
  private let now: () -> Date
  private let usageStore: UsageStore
  private let contextProvider: any ContextProvider
  private let preferences: UserDefaults
  private let websitePreferenceKey: String
  private let hideCodesPreferenceKey: String
  private let showSuggestionsPreferenceKey: String
  private let keymapPreferenceKey: String
  private var login: LoginFlow?
  private var contextTask: Task<Void, Never>?
  private var contextWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var copiedTask: Task<Void, Never>?
  private var clipboardTask: Task<Void, Never>?
  private var lockTask: Task<Void, Never>?
  private let clipboardLifetime: Duration
  private let lockDelay: Duration

  public init(
    config: Config = AppModel.configuration(),
    sessionStore: SessionStore = SessionStore(protection: .userPresence),
    cacheStore: CacheStore = CacheStore(), pasteboard: NSPasteboard = .general,
    contextProvider: (any ContextProvider)? = nil, preferences: UserDefaults = .standard,
    loginItem: (any LoginItemManaging)? = nil, now: @escaping () -> Date = Date.init,
    clipboardLifetime: Duration = .seconds(30), lockDelay: Duration = .seconds(15 * 60)
  ) {
    self.loginItem = loginItem ?? SystemLoginItem()
    loginItemStatus = self.loginItem.status
    codeSampleDate = now()
    self.config = config
    self.sessionStore = sessionStore
    self.cacheStore = cacheStore
    self.pasteboard = pasteboard
    self.now = now
    self.contextProvider = contextProvider ?? LiveContextProvider()
    self.preferences = preferences
    showSuggestionsPreferenceKey = "showSuggestions.\(cacheStore.url.deletingLastPathComponent().path)"
    showSuggestions = preferences.object(forKey: showSuggestionsPreferenceKey) as? Bool ?? true
    let profile = cacheStore.url.deletingLastPathComponent().path
    keymapPreferenceKey = "shortcuts.\(profile)"
    keymap = Self.loadKeymap(preferences, key: keymapPreferenceKey, legacyKey: "globalShortcut.\(profile)")
    hideCodesPreferenceKey = "hideCodes.\(cacheStore.url.deletingLastPathComponent().path)"
    hideCodes = preferences.bool(forKey: hideCodesPreferenceKey)
    websitePreferenceKey = "websiteSuggestions.\(cacheStore.url.deletingLastPathComponent().path)"
    websiteSuggestions = preferences.bool(forKey: websitePreferenceKey)
    usageStore = UsageStore(cacheURL: cacheStore.url)
    usage = (try? usageStore.load()) ?? UsageHistory()
    self.clipboardLifetime = clipboardLifetime
    self.lockDelay = lockDelay
  }

  convenience init(
    snapshotPhase: Phase, search: String = "", copiedID: String? = nil,
    snapshotState: VaultState? = nil, context: ForegroundContext? = nil,
    usage: UsageHistory = UsageHistory(), websiteSuggestions: Bool = true,
    hideCodes: Bool = false, optionHeld: Bool = false, allExpanded: Bool = false,
    shortcutEditor: ShortcutEditor? = nil, unavailableGlobalShortcut: KeyCombo? = nil
  ) {
    self.init(
      config: Self.configuration(environment: ["ENTE_MENUBAR_API_ORIGIN": "http://127.0.0.1:1"]),
      cacheStore: CacheStore(url: URL(fileURLWithPath: "/dev/null/snapshot/cache.bin")))
    self.shortcutEditor = shortcutEditor
    self.unavailableGlobalShortcut = unavailableGlobalShortcut
    self.allExpanded = allExpanded
    self.hideCodes = hideCodes
    self.optionHeld = optionHeld
    self.phase = snapshotPhase
    self.context = context
    self.usage = usage
    self.websiteSuggestions = websiteSuggestions
    self.snapshotState = snapshotState
    self.search = search
    self.copiedID = copiedID
    if let snapshotState { selectedRowID = rows(for: snapshotState).first(where: \.selectable)?.id }
    else { selectFirst() }
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
    sessionStore.deleteLegacyLoginKeychainItem()
    do {
      phase = try sessionStore.containsSession() ? .locked : .signedOut(SignIn())
      if shouldAutoUnlock { await unlock() }
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
      let restored = (try? vault.codes(nowUnixMs: timestamp))?.isEmpty == false
      try open(vault, lastSync: restored ? cacheStore.modifiedAt : nil)
      onSystemPromptFinished?()
      Task { await sync() }
    } catch {
      guard case .unlocking(let current) = phase, current == attempt else { return }
      phase = .locked
      if (error as? StorageError)?.isCancelled != true { unlockError = message(error) }
      onSystemPromptFinished?()
    }
  }

  public func requestClose() { onClose?() }

  public func lock() {
    optionHeld = false
    switch phase {
    case .ready, .unlocking:
      phase = .locked
      endContextLookup()
      context = nil
      resetSelection()
      lockTask?.cancel()
    case .launching, .signedOut, .locked:
      break
    }
  }

  public func setEmail(_ email: String) {
    guard case .signedOut(var signIn) = phase, signIn.step == .credentials, !signIn.busy else { return }
    signIn.email = email
    phase = .signedOut(signIn)
  }

  public func submit(password: String, code: String = "") async {
    guard case .signedOut(var signIn) = phase, !signIn.busy,
      signIn.step != .passkeyUnsupported
    else { return }
    signIn.error = nil
    if signIn.step == .credentials {
      signIn.email = signIn.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if signIn.email.isEmpty {
        signIn.error = "Enter your email."
      } else if password.isEmpty {
        signIn.error = "Enter your password."
      }
    } else if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      signIn.error = "Enter your verification code."
    }
    if signIn.error != nil {
      phase = .signedOut(signIn)
      return
    }
    signIn.busy = true
    phase = .signedOut(signIn)
    let flow: LoginFlow
    do {
      if signIn.step == .credentials {
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
      var step: LoginStep
      switch signIn.step {
      case .credentials: step = try await flow.prepare(email: signIn.email)
      case .emailCode, .authenticatorCode:
        step = try await flow.submitCode(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
      case .passkeyUnsupported: return
      }
      guard login === flow else { return }
      if case .password = step {
        signIn.step = .credentials
        guard !password.isEmpty else {
          signIn.busy = false
          signIn.error = "Enter your password."
          phase = .signedOut(signIn)
          return
        }
        step = try await flow.submitPassword(password: password)
        guard login === flow else { return }
      }
      switch step {
      case .emailCode: signIn.step = .emailCode
      case .password: signIn.step = .credentials
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
    endContextLookup()
    context = nil
    usage = UsageHistory()
    usageError = nil
    resetSelection()
    unlockError = nil
    var errors: [String] = []
    do { try sessionStore.delete() } catch { errors.append(self.message(error)) }
    do { try cacheStore.delete() } catch {
      errors.append("Unable to remove the cached vault. \(error.localizedDescription)")
    }
    do { try usageStore.delete() } catch {
      errors.append("Unable to remove local code usage. \(error.localizedDescription)")
    }
    phase = .signedOut(SignIn(error: errors.isEmpty ? message : errors.joined(separator: " ")))
  }

  private func resetSelection() {
    search = ""
    selectedRowID = nil
    allExpanded = false
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
        codeSampleDate = now()
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
      if let refreshed = try? vault.codes(nowUnixMs: timestamp) {
        state.codes = refreshed
        codeSampleDate = now()
      }
    }
    session.state = state
    phase = .ready(session)
    preserveSelection()
  }

  private var shouldAutoUnlock: Bool {
    guard visible, shortcutEditor == nil, case .locked = phase else { return false }
    return true
  }

  public func setVisible(_ visible: Bool) {
    if !visible { closeShortcuts() }
    guard self.visible != visible else { return }
    self.visible = visible
    if visible { refreshLoginItemStatus() }
    lockTask?.cancel()
    if visible {
      frozenUsage = usage
      search = ""
      allExpanded = false
      openedFrom = contextProvider.application
      refreshContext()
      refreshCodes()
      selectFirst()
      if shouldAutoUnlock {
        Task { if shouldAutoUnlock { await unlock() } }
      }
    } else {
      frozenUsage = nil
      optionHeld = false
      endContextLookup()
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
      codeSampleDate = now()
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
    if contextSearch { return contextMatches(session.state.codes, context: context, usage: layoutUsage, now: now()) }
    return rankedCodes(session.state.codes, query: search, usage: layoutUsage, now: now())
  }

  var rows: [DiscoveryRow] {
    if case .ready(let session) = phase { return rows(for: session.state) }
    return snapshotState.map { rows(for: $0) } ?? []
  }

  func rows(for state: VaultState) -> [DiscoveryRow] {
    discoveryRows(codes: state.codes, query: search, usage: layoutUsage, context: context,
      websiteSuggestions: websiteSuggestions, allExpanded: allExpanded, now: now(),
      contextSearch: contextSearch, showSuggestions: showSuggestions)
  }

  public func setShowSuggestions(_ enabled: Bool) {
    showSuggestions = enabled
    preferences.set(enabled, forKey: showSuggestionsPreferenceKey)
    contextSearch = false
    refreshContext()
    preserveSelection()
  }

  func dismissSuggestion(id: String) {
    guard let context, let code = rows.compactMap(\.code).first(where: { $0.id == id }) else { return }
    usage.dismiss(code, context: context)
    frozenUsage?.dismiss(code, context: context)
    do {
      try usageStore.save(usage)
      usageError = nil
    } catch { usageError = "Unable to save suggestion preferences." }
    preserveSelection()
  }

  private static func loadKeymap(_ preferences: UserDefaults, key: String, legacyKey: String) -> Keymap {
    if let keymap = Keymap(stored: preferences.data(forKey: key)) { return keymap }
    var keymap = Keymap()
    if preferences.object(forKey: legacyKey) as? Bool == false { keymap.clear(.openEnteAuth) }
    return keymap
  }

  public func configureGlobalShortcut(_ register: @escaping @MainActor (KeyCombo?) throws -> Void) {
    globalRegistration = register
    _ = reconcileGlobalShortcut()
  }

  public func handleKeyPress(_ press: KeyCombo) -> Bool {
    switch shortcutEditor {
    case .recording(let action, _):
      if press == .escape { setRecording(nil) }
      else if press == .tab { setRecording(nil); return false }
      else { record(press, for: action) }
      return true
    case .browsing:
      guard press == .escape else { return false }
      closeShortcuts()
      return true
    case nil:
      guard let action = keymap.action(for: press), !action.isGlobal else { return false }
      guard case .ready = phase else { return true }
      switch action {
      case .copyNextCode: copy(moment: .next)
      case .syncNow: Task { await sync() }
      case .lock: lock()
      case .openEnteAuth: break
      }
      return true
    }
  }

  func showShortcuts() {
    if shortcutEditor == nil { shortcutEditor = .browsing }
    onOpen?()
  }

  func closeShortcuts() {
    guard shortcutEditor != nil else { return }
    shortcutEditor = nil
    _ = reconcileGlobalShortcut()
  }

  func setRecording(_ action: ShortcutAction?) {
    guard shortcutEditor != nil else { return }
    shortcutEditor = action.map { .recording($0, problem: nil) } ?? .browsing
    _ = reconcileGlobalShortcut()
  }

  func clearShortcut(_ action: ShortcutAction) {
    var next = keymap
    next.clear(action)
    commitShortcuts(next)
  }

  func restoreDefaultShortcuts() { commitShortcuts(Keymap()) }

  private func record(_ combo: KeyCombo, for action: ShortcutAction) {
    var next = keymap
    do throws(ShortcutProblem) {
      try next.assign(combo, to: action, in: .current)
    } catch {
      shortcutEditor = .recording(action, problem: error)
      return
    }
    commitShortcuts(next)
  }

  private func commitShortcuts(_ next: Keymap) {
    if next.combo(for: .openEnteAuth) != keymap.combo(for: .openEnteAuth),
      let problem = reconcileGlobalShortcut(committing: next) {
      if case .recording(let action, _) = shortcutEditor {
        unavailableGlobalShortcut = nil
        shortcutEditor = .recording(action, problem: problem)
      } else {
        _ = reconcileGlobalShortcut()
        unavailableGlobalShortcut = next.combo(for: .openEnteAuth)
      }
      return
    }
    keymap = next
    preferences.set(keymap.stored, forKey: keymapPreferenceKey)
    if shortcutEditor != nil { shortcutEditor = .browsing }
    _ = reconcileGlobalShortcut()
  }

  private func reconcileGlobalShortcut(committing candidate: Keymap? = nil) -> ShortcutProblem? {
    var desired = (candidate ?? keymap).combo(for: .openEnteAuth)
    if candidate == nil, case .recording = shortcutEditor { desired = nil }
    do {
      try globalRegistration?(desired)
      unavailableGlobalShortcut = nil
      return nil
    } catch {
      unavailableGlobalShortcut = desired
      return desired.map { .unavailable($0) }
    }
  }

  public func refreshLoginItemStatus() { loginItemStatus = loginItem.status }

  public func toggleLaunchAtLogin() {
    refreshLoginItemStatus()
    if loginItemStatus == .requiresApproval {
      loginItem.openSettings()
      return
    }
    do {
      try loginItem.setEnabled(loginItemStatus != .enabled)
      settingsError = nil
    } catch { settingsError = "Unable to change Launch at Login. \(error.localizedDescription)" }
    refreshLoginItemStatus()
    if loginItemStatus == .requiresApproval { loginItem.openSettings() }
  }

  public func setHideCodes(_ enabled: Bool) {
    hideCodes = enabled
    preferences.set(enabled, forKey: hideCodesPreferenceKey)
  }

  public func setOptionHeld(_ held: Bool) {
    optionHeld = held && visible
  }

  public func setWebsiteSuggestions(_ enabled: Bool) {
    websiteSuggestions = enabled
    preferences.set(enabled, forKey: websitePreferenceKey)
    refreshContext()
  }

  func allowWebsiteSuggestions() {
    websiteSuggestions = true
    preferences.set(true, forKey: websitePreferenceKey)
    if let application = context?.application, application.isBrowser, !requestingWebsiteAccess {
      requestingWebsiteAccess = true
      endContextLookup()
      Task { [weak self, contextProvider] in
        await contextProvider.requestWebsiteAccess(for: application)
        guard let self else { return }
        self.requestingWebsiteAccess = false
        self.refreshContext()
        self.onSystemPromptFinished?()
      }
    } else { refreshContext() }
  }

  func openWebsiteAccessSettings() { contextProvider.openWebsiteAccessSettings() }

  public func contextSettled(within cap: Duration) async {
    guard contextTask != nil else { return }
    let id = UUID()
    let timer = Task { [weak self] in
      do { try await Task.sleep(for: cap) } catch { return }
      self?.contextWaiters.removeValue(forKey: id)?.resume()
    }
    await withCheckedContinuation { contextWaiters[id] = $0 }
    timer.cancel()
  }

  private func endContextLookup() {
    contextTask?.cancel()
    contextTask = nil
    let waiters = contextWaiters.values
    contextWaiters = [:]
    for waiter in waiters { waiter.resume() }
  }

  private func refreshContext() {
    endContextLookup()
    guard showSuggestions, case .ready = phase, let application = openedFrom else {
      context = nil
      return
    }
    context = ForegroundContext(application: application)
    selectFirst()
    guard websiteSuggestions, application.isBrowser else { return }
    contextTask = Task { [weak self, contextProvider, websiteSuggestions] in
      let result = await contextProvider.context(for: application, websiteSuggestions: websiteSuggestions)
      guard !Task.isCancelled, let self else { return }
      if self.visible, case .ready = self.phase {
        self.context = result
        if self.search.isEmpty { self.selectFirst() }
        else { self.preserveSelection() }
      }
      self.endContextLookup()
    }
  }

  public func moveSelection(_ offset: Int) {
    let selectable = rows.filter(\.selectable)
    guard !selectable.isEmpty else { return }
    let index = selectable.firstIndex { $0.id == selectedRowID } ?? 0
    selectedRowID = selectable[min(max(index + offset, 0), selectable.count - 1)].id
  }

  func select(_ id: DiscoveryRowID) {
    if selectedRowID != id { selectedRowID = id }
  }

  func activateSelection() {
    if let selectedRowID { activate(selectedRowID) }
  }

  func activate(_ id: DiscoveryRowID) {
    guard let row = rows.first(where: { $0.id == id }) else { return }
    selectedRowID = id
    switch row {
    case .code(_, let code): copy(id: code.id)
    case .more(_, let label):
      search = label
      contextSearch = true
      selectFirst()
    case .showAll:
      allExpanded = true
      selectedRowID = rows.first { if case .code(.all, _) = $0 { true } else { false } }?.id
    case .websiteSetup(.turnOn), .websiteSetup(.allow): allowWebsiteSuggestions()
    case .websiteSetup(.openSettings): openWebsiteAccessSettings()
    case .header: break
    }
  }

  public enum CodeMoment { case current, next }

  public func copy(id: String? = nil, moment: CodeMoment = .current) {
    guard case .ready(let session) = phase, let id = id ?? selectedID,
      let code = try? session.vault.codes(nowUnixMs: timestamp).first(where: { $0.id == id }),
      code.kind != .hotp, !code.display.trashed
    else { return }
    if selectedID != id { selectedRowID = rows.first { $0.code?.id == id }?.id }
    let item = NSPasteboardItem()
    item.setString(moment == .current ? code.current : code.next, forType: .string)
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { return }
    usage.record(code, context: context, at: now())
    do {
      try usageStore.save(usage)
      usageError = nil
    } catch { usageError = "Unable to save local code usage." }
    preserveSelection()
    let changeCount = pasteboard.changeCount
    clipboardTask?.cancel()
    clipboardTask = Task { [pasteboard, clipboardLifetime] in
      do { try await Task.sleep(for: clipboardLifetime) } catch { return }
      if pasteboard.changeCount == changeCount { pasteboard.clearContents() }
    }
    copiedNext = moment == .next
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
    codeSampleDate = now()
    phase = .ready(
      VaultSession(
        vault: vault,
        state: VaultState(
          codes: codes, lastSuccessfulSync: lastSync, syncStatus: .idle,
          unreadableCount: vault.unreadableCount())))
    if visible { refreshContext() }
    selectFirst()
    if !visible { scheduleLock() }
  }

  private func selectFirst() { selectedRowID = rows.first(where: \.selectable)?.id }

  private func preserveSelection() {
    if !rows.contains(where: { $0.id == selectedRowID }) { selectFirst() }
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
