import AppKit
import EnteBridge
import SwiftUI

@MainActor public func renderSnapshots(to directory: URL) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let codes = [
    snapshotCode("GitHub", "personal", current: "800882", pinned: true),
    snapshotCode("Google", "personal", current: "226491", pinned: true),
    snapshotCode("AWS", "production", current: "307510"),
    snapshotCode("Counter", "work", kind: .hotp, current: ""),
    snapshotCode("Steam", "personal", kind: .steam, current: "PV9M4"),
  ]
  let ready = VaultState(
    codes: codes, lastSuccessfulSync: Date(), syncStatus: .idle, unreadableCount: 0)
  let offline = VaultState(
    codes: codes, lastSuccessfulSync: Date().addingTimeInterval(-300),
    syncStatus: .offline(since: Date()), unreadableCount: 2)
  let scenes: [(String, AppModel, ColorScheme)] = [
    ("email", AppModel(snapshotPhase: .signedOut(SignIn())), .light),
    (
      "password",
      AppModel(snapshotPhase: .signedOut(SignIn(email: "user@example.com", step: .password))),
      .light
    ),
    (
      "code-error",
      AppModel(
        snapshotPhase: .signedOut(
          SignIn(
            email: "user@example.com", step: .emailCode,
            error: "Incorrect or expired code. Try again."))), .light
    ),
    ("ready-light", AppModel(snapshotPhase: .ready(ready)), .light),
    ("ready-dark", AppModel(snapshotPhase: .ready(ready)), .dark),
    ("copied", AppModel(snapshotPhase: .ready(ready), copiedID: "GitHub"), .light),
    ("search-empty", AppModel(snapshotPhase: .ready(ready), search: "nothing matches"), .light),
    ("offline", AppModel(snapshotPhase: .ready(offline)), .light),
  ]
  for (name, model, scheme) in scenes {
    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let host = NSHostingView(
      rootView: PopoverView(model: model).background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(
      contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw SnapshotError.render(name)
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw SnapshotError.render(name)
    }
    let url = directory.appending(path: "\(name).png")
    try png.write(to: url)
    print(url.path)
  }
}

private enum SnapshotError: Error {
  case render(String)
}

private func snapshotCode(
  _ issuer: String, _ account: String, kind: CodeKind = .totp,
  current: String, pinned: Bool = false
) -> CodeView {
  CodeView(
    id: issuer, issuer: issuer, account: account, kind: kind, current: current, next: "359152",
    periodSecs: kind == .hotp ? 0 : 30, remainingMs: kind == .hotp ? 0 : 4000,
    display: Display(
      pinned: pinned, trashed: false, tags: [], note: "", iconSrc: "", iconId: "",
      tapCount: 0, lastUsedAt: 0))
}
