import AppKit
import EnteBridge
import SwiftUI

public struct PopoverView: View {
  @Bindable private var model: AppModel

  public init(model: AppModel) { self.model = model }

  public var body: some View {
    Group {
      switch model.phase {
      case .launching:
        ProgressView("Opening vault…").frame(height: 180)
      case .signedOut(let signIn):
        SignInView(model: model, signIn: signIn)
      case .locked, .unlocking:
        LockedView(model: model)
      case .ready(let session):
        VaultView(model: model, state: session.state)
      }
    }
    .frame(width: 348)
    .background(.regularMaterial)
    .background(WindowVisibility { model.setVisible($0) })
    .task(id: model.visible) {
      guard model.visible else { return }
      Task { await model.sync() }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        model.refreshCodes()
      }
    }
    .onDisappear { model.setVisible(false) }
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
  @State private var value = ""
  @FocusState private var focused: Bool

  private var title: String {
    switch signIn.step {
    case .email: "Sign in to Ente Auth"
    case .password: "Enter your password"
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
        if signIn.step != .email {
          Text(signIn.email).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(
            .enabled)
        }
      }
      if signIn.step == .passkeyUnsupported {
        Text("Passkey sign-in isn't supported yet.").font(.system(size: 13))
      } else {
        VStack(alignment: .leading, spacing: 7) {
          Text(fieldLabel).font(.system(size: 12, weight: .medium))
          field
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .focused($focused)
            .disabled(signIn.busy)
            .onSubmit { submit() }
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
        Button(action: submit) {
          HStack(spacing: 8) {
            if signIn.busy { ProgressView().controlSize(.small) }
            Text("Continue")
          }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(signIn.busy)
      }
      HStack {
        if signIn.step != .email {
          Button("Use a different email") { Task { await model.signOut() } }
        }
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color.accentColor)
      .font(.system(size: 12))
    }
    .padding(22)
    .onAppear { focused = true }
    .onChange(of: signIn.step) { _, _ in
      value = ""
      focused = true
    }
    .onChange(of: signIn.busy) { _, busy in if !busy { focused = true } }
  }

  private var fieldLabel: String {
    switch signIn.step {
    case .email: "Email"
    case .password: "Password"
    case .emailCode: "Email code"
    case .authenticatorCode: "Authenticator code"
    case .passkeyUnsupported: ""
    }
  }

  @ViewBuilder private var field: some View {
    switch signIn.step {
    case .email:
      TextField("name@example.com", text: Binding(get: { signIn.email }, set: model.setEmail))
        .textContentType(.username)
        .accessibilityLabel("Email")
    case .password:
      SecureField("Password", text: $value).textContentType(.password)
        .accessibilityLabel("Password")
    case .emailCode, .authenticatorCode:
      TextField("123456", text: $value).textContentType(.oneTimeCode)
        .accessibilityLabel(fieldLabel)
    case .passkeyUnsupported:
      EmptyView()
    }
  }

  private func submit() {
    let submitted = value
    value = ""
    Task { await model.submit(submitted) }
  }
}

struct VaultView: View {
  @Bindable var model: AppModel
  let state: VaultState
  @FocusState private var searchFocused: Bool

  var body: some View {
    let codes = state.filteredCodes(search: model.search)
    let pinned = codes.filter(\.display.pinned)
    let others = codes.filter { !$0.display.pinned }
    let timedCode = codes.filter { $0.kind != .hotp }.min { $0.periodSecs < $1.periodSecs }
    let count = state.codes.filter { !$0.display.trashed }.count
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField("Search \(count) codes", text: $model.search)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .accessibilityLabel("Search codes")
          .onSubmit { model.copy() }
          .onKeyPress(.downArrow) {
            model.moveSelection(1)
            return .handled
          }
          .onKeyPress(.upArrow) {
            model.moveSelection(-1)
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
      .padding(.horizontal, 10)
      .padding(.top, 10)

      GeometryReader { geometry in
        let progress =
          timedCode.map { Double($0.remainingMs) / Double(max($0.periodSecs, 1) * 1000) } ?? 0
        Capsule().fill(.quaternary)
          .overlay(alignment: .leading) {
            Capsule().fill(
              timedCode.map { $0.remainingMs <= 5000 } == true ? Color.orange : Color.accentColor
            )
            .frame(width: geometry.size.width * min(max(progress, 0), 1))
          }
      }
      .frame(height: 3)
      .padding(.horizontal, 12)
      .padding(.top, 9)
      .padding(.bottom, 2)
      .accessibilityLabel("Code refresh countdown")
      .accessibilityValue("\((timedCode?.remainingMs ?? 0) / 1000) seconds")

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if codes.isEmpty {
              emptyState
            } else {
              if !pinned.isEmpty { section("Pinned", codes: pinned) }
              if !others.isEmpty { section("All codes", codes: others) }
            }
          }.padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(height: listHeight(codes: codes.count, pinned: pinned.count))
        .onChange(of: model.selectedID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      Divider()
      VaultFooter(state: state, count: count, signOut: { Task { await model.signOut() } })
    }
    .onAppear { searchFocused = true }
    .onChange(of: model.visible) { _, visible in if visible { searchFocused = true } }
  }

  private func listHeight(codes: Int, pinned: Int) -> CGFloat {
    if codes == 0 { return 132 }
    let sections = (pinned == 0 ? 0 : 1) + (pinned == codes ? 0 : 1)
    return min(440, CGFloat(codes * 48 + sections * 27 + 6))
  }

  private func section(_ title: String, codes: [CodeView]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.leading, 10).padding(.top, 9).padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
      ForEach(codes, id: \.id) { code in
        CodeRow(
          code: code, selected: model.selectedID == code.id, copied: model.copiedID == code.id
        ) {
          model.copy(id: code.id)
          searchFocused = true
        }.id(code.id)
      }
    }
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
  let copy: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: copy) {
      HStack(spacing: 10) {
        Text(String((code.issuer.isEmpty ? code.account : code.issuer).prefix(1)).uppercased())
          .font(.system(size: 12, weight: .bold))
          .frame(width: 26, height: 26)
          .foregroundStyle(.white)
          .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(code.issuer.isEmpty ? code.account : code.issuer).font(
            .system(size: 13, weight: .semibold))
          Text(code.account).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .help("\(code.issuer)\n\(code.account)")
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 1) {
          if code.kind == .hotp {
            Text("HOTP isn't supported yet").font(.system(size: 11)).foregroundStyle(.secondary)
              .frame(maxWidth: 110, alignment: .trailing).multilineTextAlignment(.trailing)
          } else if copied {
            Label("Copied", systemImage: "checkmark").font(.system(size: 14, weight: .semibold))
              .foregroundStyle(.green)
          } else {
            Text(grouped(code.current)).font(.system(size: 18, weight: .medium)).monospacedDigit()
            if selected && code.remainingMs <= 5000 {
              Text("next \(grouped(code.next))").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
        }.fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      selected ? Color.accentColor.opacity(0.15) : hovered ? Color.primary.opacity(0.05) : .clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .onHover { hovered = $0 }
    .accessibilityLabel(
      "\(code.issuer), \(code.account), \(code.kind == .hotp ? "HOTP isn't supported yet" : copied ? "Copied" : grouped(code.current))"
    )
    .accessibilityHint(code.kind == .hotp ? "" : "Copy current code")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private func grouped(_ code: String) -> String {
    guard code.count == 6, code.allSatisfy(\.isNumber) else { return code }
    return "\(code.prefix(3)) \(code.suffix(3))"
  }
}

struct VaultFooter: View {
  let state: VaultState
  let count: Int
  let signOut: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(status) · \(count) \(count == 1 ? "code" : "codes")")
        if case .failed(let message) = state.syncStatus { Text(message).foregroundStyle(.red) }
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
      Menu {
        Button("Sign Out", action: signOut)
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
      } label: {
        Image(systemName: "ellipsis.circle").font(.system(size: 15))
          .frame(width: 24, height: 24)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Account menu")
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

private struct WindowVisibility: NSViewRepresentable {
  let changed: (Bool) -> Void

  func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
  func updateNSView(_ nsView: VisibilityView, context: Context) {}

  final class VisibilityView: NSView {
    let changed: (Bool) -> Void

    init(changed: @escaping (Bool) -> Void) {
      self.changed = changed
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      if let window {
        for name in [
          NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
          NSWindow.didResignKeyNotification,
        ] {
          NotificationCenter.default.addObserver(
            self, selector: #selector(updateVisibility), name: name, object: window)
        }
      }
      updateVisibility()
    }

    @objc private func updateVisibility() {
      let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
      Task { @MainActor in changed(visible) }
    }
  }
}
