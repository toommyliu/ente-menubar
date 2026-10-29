import AppKit
import EnteBridge
import SwiftUI

public struct PopoverView: View {
  @Bindable private var model: AppModel

  public init(model: AppModel) { self.model = model }

  private var phaseKey: Int {
    if model.shortcutEditor != nil { return 4 }
    switch model.phase {
    case .launching: return 0
    case .signedOut: return 1
    case .locked, .unlocking: return 2
    case .ready: return 3
    }
  }

  public var body: some View {
    Group {
      if let editor = model.shortcutEditor {
        ShortcutsView(model: model, editor: editor).transition(.opacity)
      } else {
        switch model.phase {
        case .launching:
          ProgressView("Opening vault…").frame(height: 180).transition(.opacity)
        case .signedOut(let signIn):
          SignInView(model: model, signIn: signIn).transition(.opacity)
        case .locked, .unlocking:
          LockedView(model: model).transition(.opacity)
        case .ready(let session):
          VaultView(model: model, state: session.state).transition(.opacity)
        }
      }
    }
    .animation(.easeInOut(duration: 0.2), value: phaseKey)
    .frame(width: 348)
    .onExitCommand { model.requestClose() }
    .background(.regularMaterial)
    .task(id: model.visible) {
      guard model.visible else { return }
      Task { await model.sync() }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        model.refreshCodes()
      }
    }
  }
}

struct LockedView: View {
  @Bindable var model: AppModel

  private var unlocking: Bool {
    if case .unlocking = model.phase { return true }
    return false
  }

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "lock.shield").font(.system(size: 30)).foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Ente Auth is locked").font(.system(size: 20, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text("Unlock with Touch ID or your Mac password to see codes.")
        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if let error = model.unlockError {
        Text(error).font(.system(size: 12)).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button {
        Task { await model.unlock() }
      } label: {
        HStack(spacing: 8) {
          if unlocking { ProgressView().controlSize(.small) }
          Text("Unlock")
        }.frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent).controlSize(.large)
      .keyboardShortcut(.defaultAction).disabled(unlocking)
      HStack {
        Button("Sign Out") { Task { await model.signOut() } }
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
      }
      .buttonStyle(.link).font(.system(size: 12)).disabled(unlocking)
    }
    .padding(24)
  }
}

private struct SignInView: View {
  @Bindable var model: AppModel
  let signIn: SignIn
  @State private var password = ""
  @State private var code = ""
  private enum Field: Hashable { case email, password, code }
  @FocusState private var focused: Field?

  private var title: String {
    switch signIn.step {
    case .credentials: "Sign in to Ente Auth"
    case .emailCode: "Check your email"
    case .authenticatorCode: "Enter authenticator code"
    case .passkeyUnsupported: "Passkey sign-in"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Ente Auth", systemImage: "lock.shield")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
        if signIn.step != .credentials {
          Text(signIn.email).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(
            .enabled)
        }
      }
      if signIn.step == .passkeyUnsupported {
        Text("Passkey sign-in isn't supported yet.").font(.system(size: 13))
      } else {
        VStack(alignment: .leading, spacing: 12) {
          if signIn.step == .credentials {
            VStack(alignment: .leading, spacing: 7) {
              Text("Email").font(.system(size: 12, weight: .medium))
              TextField("name@example.com", text: Binding(get: {
                guard case .signedOut(let current) = model.phase else { return "" }
                return current.email
              }, set: model.setEmail))
                .textContentType(nil)
                .accessibilityLabel("Email")
                .focused($focused, equals: .email)
                .onSubmit { focused = .password }
            }
            VStack(alignment: .leading, spacing: 7) {
              Text("Password").font(.system(size: 12, weight: .medium))
              PasswordField(text: $password, onSubmit: submit)
                .focused($focused, equals: .password)
            }
          } else {
            VStack(alignment: .leading, spacing: 7) {
              Text(codeLabel).font(.system(size: 12, weight: .medium))
              TextField("123456", text: $code)
                .textContentType(.oneTimeCode)
                .accessibilityLabel(codeLabel)
                .focused($focused, equals: .code)
                .onSubmit { submit() }
            }
          }
          if signIn.step == .emailCode {
            Button("Resend code") { Task { await model.resendCode() } }
              .buttonStyle(.link)
              .disabled(signIn.busy)
              .font(.system(size: 12))
          }
          if let error = signIn.error {
            Label(error, systemImage: "exclamationmark.circle")
              .font(.system(size: 12))
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityLabel(error)
          }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .disabled(signIn.busy)
        Button(action: submit) {
          HStack(spacing: 8) {
            if signIn.busy { ProgressView().controlSize(.small) }
            Text(signIn.step == .credentials ? "Sign in" : "Verify")
          }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(signIn.busy)
      }
      HStack {
        if signIn.step != .credentials {
          Button("Use a different email") {
            password = ""
            code = ""
            Task { await model.signOut() }
          }.disabled(signIn.busy)
        }
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color.accentColor)
      .font(.system(size: 12))
    }
    .padding(22)
    .onAppear { focusField() }
    .onChange(of: model.visible) { _, visible in if visible { focusField() } }
    .onChange(of: signIn.busy) { _, busy in if !busy { focusField() } }
    .onChange(of: signIn.step) { _, step in
      code = ""
      if step == .passkeyUnsupported { password = "" }
      focusField()
    }
  }

  private var codeLabel: String {
    signIn.step == .emailCode ? "Email code" : "Authenticator code"
  }

  private func focusField() {
    guard case .signedOut(let signIn) = model.phase else { return }
    switch signIn.step {
    case .credentials: focused = signIn.email.isEmpty ? .email : .password
    case .emailCode, .authenticatorCode: focused = .code
    case .passkeyUnsupported: focused = nil
    }
  }

  private func submit() {
    let password = password
    let code = code
    focused = nil
    Task {
      await model.submit(password: password, code: code)
      if case .signedOut = model.phase {
        focusField()
      } else {
        self.password = ""
        self.code = ""
      }
    }
  }
}

struct VaultView: View {
  @Bindable var model: AppModel
  let state: VaultState
  @FocusState private var searchFocused: Bool

  var body: some View {
    let rows = model.rows(for: state)
    let timing = CodeTiming.selected(in: rows, selection: model.selectedRowID)
    let count = state.codes.filter { !$0.display.trashed }.count
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField(count > 0 ? "Search \(count) codes" : "Search codes", text: $model.search)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .accessibilityLabel("Search codes")
          .onSubmit { model.activateSelection() }
          .onKeyPress(.downArrow) {
            model.moveSelection(1)
            return .handled
          }
          .onKeyPress(.upArrow) {
            model.moveSelection(-1)
            return .handled
          }
          .onKeyPress(.escape) {
            if model.search.isEmpty { model.requestClose() } else { model.search = "" }
            return .handled
          }
        if !model.search.isEmpty {
          Button {
            model.search = ""
            searchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }.buttonStyle(.plain).accessibilityLabel("Clear search")
        }
      }
      .font(.system(size: 13))
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
      .overlay(alignment: .bottom) {
        CountdownLine(timing: timing, sampledAt: model.codeSampleDate, paused: !model.visible)
      }
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 4)

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
              if model.search.isEmpty && state.codes.isEmpty && state.lastSuccessfulSync == nil {
                firstSyncState
              } else {
                emptyState
              }
            } else {
              ForEach(rows) { row in
                discoveryRow(row).id(row.id)
              }
            }
          }
          .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .scrollIndicators(.never)
        .frame(height: listHeight(rows))
        .onChange(of: model.selectedRowID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      Divider()
      VaultFooter(model: model, state: state, count: count)
    }
    .onAppear { searchFocused = true }
    .onChange(of: model.visible) { _, visible in if visible { searchFocused = true } }
  }

  private func listHeight(_ rows: [DiscoveryRow]) -> CGFloat {
    if rows.isEmpty { return 132 }
    return min(440, rows.reduce(CGFloat(6)) { height, row in
      switch row {
      case .header: height + 27
      case .code: height + 42
      case .more, .showAll, .websiteSetup: height + 32
      }
    })
  }

  @ViewBuilder private func discoveryRow(_ row: DiscoveryRow) -> some View {
    switch row {
    case .header(let section, let note):
      HStack(spacing: 5) {
        Text(section == .results ? note ?? "Results" : section.rawValue)
          .font(.system(size: 11, weight: .semibold))
        if section != .results, let note {
          Text(note).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 4)
      .accessibilityAddTraits(.isHeader)
    case .code(let section, let code):
      CodeRow(
        code: code, selected: model.selectedRowID == row.id, copied: model.copiedID == code.id,
        copiedNext: model.copiedNext,
        copy: {
          model.activate(row.id)
          searchFocused = true
        },
        hover: { model.select(row.id) }, hidden: model.codesHidden,
        copyNext: { model.copy(id: code.id, moment: .next) },
        dismissSuggestion: section == .suggested ? { model.dismissSuggestion(id: code.id) } : nil)
    case .more(let count, let label):
      actionRow("\(count) more for \(label)", row: row)
    case .showAll(let count):
      actionRow("Show \(count) \(count == 1 ? "code" : "codes")", row: row)
    case .websiteSetup(let setup):
      switch setup {
      case .turnOn:
        actionRow("Suggest codes for the website you're on", row: row, quiet: true)
      case .allow(let name):
        actionRow("Needs access to \(name)", row: row, action: "Allow…")
          .help("Ente Auth reads the website address from \(name) to suggest codes. Only the hostname is used.")
      case .openSettings(let name):
        actionRow("\(name) access is off", row: row, action: "Open Settings")
          .help("In Automation settings, expand EnteMenubar and turn on \(name).")
      }
    }
  }

  private func actionRow(_ title: String, row: DiscoveryRow, quiet: Bool = false, action: String? = nil) -> some View {
    Button {
      model.activate(row.id)
      searchFocused = true
    } label: {
      HStack(spacing: 4) {
        Text(title).lineLimit(1)
        Spacer(minLength: 0)
        if let action { Text(action).foregroundStyle(Color.accentColor) }
        else if !quiet { Image(systemName: "chevron.right").font(.system(size: 10)) }
      }
      .font(.system(size: 11))
      .foregroundStyle(quiet || action != nil ? Color.secondary : Color.accentColor)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, minHeight: 32)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(model.selectedRowID == row.id ? Color.primary.opacity(0.07) : .clear,
      in: RoundedRectangle(cornerRadius: 6))
    .onHover { if $0 { model.select(row.id) } }
    .accessibilityAddTraits(model.selectedRowID == row.id ? [.isSelected] : [])
  }

  private var firstSyncState: some View {
    VStack(spacing: 8) {
      switch state.syncStatus {
      case .offline:
        Text("Can't reach Ente").font(.system(size: 13, weight: .medium))
        Text("Your codes appear once you're online.").font(.system(size: 12)).foregroundStyle(.secondary)
      case .failed(let message):
        Text("Couldn't load your codes").font(.system(size: 13, weight: .medium))
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
      case .idle, .syncing:
        ProgressView().controlSize(.small)
        Text("Syncing your codes…").font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, minHeight: 126)
    .padding(.horizontal, 12)
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Text(model.search.isEmpty ? "No codes yet" : "No codes match '\(model.search)'")
        .font(.system(size: 13, weight: .medium))
      if model.search.isEmpty {
        Text("Add codes in Ente Auth, then reopen this menu.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      } else {
        Button("Clear search") { model.search = "" }.buttonStyle(.plain).foregroundStyle(
          Color.accentColor
        ).font(.system(size: 12))
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, minHeight: 126)
    .padding(.horizontal, 12)
  }
}

struct CodeRow: View {
  let code: CodeView
  let selected: Bool
  let copied: Bool
  let copiedNext: Bool
  let copy: () -> Void
  let hover: () -> Void
  let hidden: Bool
  let copyNext: () -> Void
  let dismissSuggestion: (() -> Void)?

  var body: some View {
    Button(action: copy) {
      HStack(spacing: 10) {
        ServiceIconTile(
          issuer: code.issuer, account: code.account,
          iconSrc: code.display.iconSrc, iconID: code.display.iconId)
        VStack(alignment: .leading, spacing: 1) {
          Text(code.issuer.isEmpty ? code.account : code.issuer).font(
            .system(size: 13, weight: .semibold))
          Text(code.account).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .help("\(code.issuer)\n\(code.account)")
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 0) {
          if code.kind == .hotp {
            Text("HOTP")
              .font(.system(size: 10.5, weight: .semibold))
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
              .help("HOTP codes aren't supported yet")
          } else if copied {
            Label(copiedNext ? "Copied next" : "Copied", systemImage: "checkmark")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.green)
              .transition(.opacity)
          } else {
            Text(CodePresentation(code.current, hidden: hidden).text).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            if selected {
              Text("next \(CodePresentation(code.next, hidden: hidden).text)").font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(CodeTiming(code: code).isExpiring ? Color.orange : Color.secondary)
            }
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.12), value: copied)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, minHeight: 42)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      if code.kind != .hotp {
        Button("Copy Code", action: copy)
        Button("Copy Next Code", action: copyNext)
      }
      if let dismissSuggestion {
        if code.kind != .hotp { Divider() }
        Button("Don't Suggest Here", action: dismissSuggestion)
      }
    }
    .background(selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
    .onHover { if $0 { hover() } }
    .accessibilityLabel(
      Text(verbatim: "\(code.issuer), \(code.account), \(code.kind == .hotp ? "HOTP isn't supported yet" : copied ? "Copied" : CodePresentation(code.current, hidden: hidden).accessibilityLabel)")
    )
    .accessibilityHint(code.kind == .hotp ? "" : "Copy current code")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

private struct CountdownLine: View {
  let timing: CodeTiming?
  let sampledAt: Date
  let paused: Bool

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || timing == nil)) {
      context in
      let period = Double(max(timing?.code.periodSecs ?? 30, 1))
      let remaining = timing?.remaining(at: context.date, sampledAt: sampledAt) ?? 0
      GeometryReader { geometry in
        Rectangle()
          .fill(remaining <= 5 ? Color.orange.opacity(0.85) : Color.accentColor.opacity(0.55))
          .frame(width: geometry.size.width * remaining / period)
      }
      .accessibilityElement()
      .accessibilityLabel("Code refresh countdown")
      .accessibilityValue("\(Int(remaining.rounded(.up))) seconds")
    }
    .frame(height: 2)
    .opacity(timing == nil ? 0 : 1)
  }
}

struct VaultFooter: View {
  @Bindable var model: AppModel
  let state: VaultState
  let count: Int

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(status) · \(count) \(count == 1 ? "code" : "codes")")
        if case .failed(let message) = state.syncStatus { Text(message).foregroundStyle(.red) }
        if let usageError = model.usageError { Text(usageError) }
        if let settingsError = model.settingsError { Text(settingsError) }
        if let combo = model.unavailableGlobalShortcut {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(ShortcutProblem.unavailable(combo).message(in: .current))
            Button("Change…") { model.showShortcuts() }.buttonStyle(.link)
              .fixedSize().accessibilityLabel("Change global shortcut")
          }
        }
        if state.unreadableCount > 0 {
          Text(
            "\(state.unreadableCount) \(state.unreadableCount == 1 ? "entry couldn't" : "entries couldn't") be read"
          )
        }
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      AccountMenuButton(model: model)
        .frame(width: 24, height: 24)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
  }

  private var status: String {
    let elapsed = state.lastSuccessfulSync.map { max(0, Int(Date().timeIntervalSince($0))) }
    let age: String
    if let elapsed {
      if elapsed < 60 {
        age = "just now"
      } else if elapsed < 3600 {
        age = "\(elapsed / 60) min ago"
      } else if elapsed < 86400 {
        age = "\(elapsed / 3600) hr ago"
      } else {
        age = "\(elapsed / 86400) days ago"
      }
    } else {
      age = "never"
    }
    switch state.syncStatus {
    case .syncing: return "Syncing…"
    case .offline: return "Offline, last synced \(age)"
    case .idle, .failed: return elapsed == nil ? "Not synced yet" : "Synced \(age)"
    }
  }
}
