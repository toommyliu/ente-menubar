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
  let largeCodes = [
    snapshotCode("GitHub", "work", current: "800882", id: "github-work", tapCount: 31),
    snapshotCode("GitHub", "release bot", current: "262575", id: "github-bot", tapCount: 20),
    snapshotCode("GitHub", "personal", current: "773431", pinned: true, id: "github-personal", tapCount: 10),
    snapshotCode("GitHub", "automation", current: "291006", id: "github-auto", tapCount: 5),
    snapshotCode("Google", "personal", current: "226491", pinned: true),
    snapshotCode("Proton", "personal", current: "250708", pinned: true),
    snapshotCode("AWS", "production", current: "307510", tapCount: 46),
    snapshotCode("Okta", "work", current: "191692", tapCount: 27),
    snapshotCode("Slack", "work", current: "586407", tapCount: 15),
    snapshotCode("Stripe", "work", current: "481903", tapCount: 12),
  ] + ["Amazon", "Apple", "Cloudflare", "Discord", "Dropbox", "Figma", "Linear", "Notion", "Steam", "Vercel"]
    .map { snapshotCode($0, "personal", current: "529180") }
  let large = VaultState(codes: largeCodes, lastSuccessfulSync: Date(), syncStatus: .idle, unreadableCount: 0)
  let browser = ApplicationContext(bundleID: "net.imput.helium", name: "Helium")
  let scenes: [(String, AnyView, ColorScheme)] = [
    ("email", AnyView(PopoverView(model: AppModel(snapshotPhase: .signedOut(SignIn())))), .light),
    ("locked", AnyView(PopoverView(model: AppModel(snapshotPhase: .locked))), .light),
    (
      "password",
      AnyView(
        PopoverView(
          model: AppModel(
            snapshotPhase: .signedOut(SignIn(email: "user@example.com", step: .password))))),
      .light
    ),
    (
      "code-error",
      AnyView(
        PopoverView(
          model: AppModel(
            snapshotPhase: .signedOut(
              SignIn(
                email: "user@example.com", step: .emailCode,
                error: "Incorrect or expired code. Try again."))))), .light
    ),
    ("ready-light", snapshotVault(ready), .light),
    ("ready-dark", snapshotVault(ready), .dark),
    ("copied", snapshotVault(ready, copiedID: "GitHub"), .light),
    ("search-empty", snapshotVault(ready, search: "nothing matches"), .light),
    ("offline", snapshotVault(offline), .light),
    ("suggested-website-more", snapshotVault(large,
      context: ForegroundContext(application: browser, hostname: "github.com")), .light),
    ("large-collapsed", snapshotVault(large), .light),
    ("search-result", snapshotVault(large, search: "aws pr"), .light),
    ("website-opt-in", snapshotVault(large,
      context: ForegroundContext(application: browser), websiteSuggestions: false), .light),
  ]
  for (name, view, scheme) in scenes {
    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let host = NSHostingView(
      rootView: view.frame(width: 348).background(Color(nsColor: .windowBackgroundColor)))
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
  current: String, pinned: Bool = false, id: String? = nil, tapCount: Int64 = 0
) -> CodeView {
  CodeView(
    id: id ?? issuer, issuer: issuer, account: account, kind: kind, current: current, next: "359152",
    periodSecs: kind == .hotp ? 0 : 30, remainingMs: kind == .hotp ? 0 : 4000,
    display: Display(
      pinned: pinned, trashed: false, tags: [], note: "", iconSrc: "", iconId: "",
      tapCount: tapCount, lastUsedAt: Int64(Date().timeIntervalSince1970 * 1000)))
}

@MainActor private func snapshotVault(
  _ state: VaultState, search: String = "", copiedID: String? = nil,
  context: ForegroundContext? = nil, websiteSuggestions: Bool = true
) -> AnyView {
  let model = AppModel(snapshotPhase: .signedOut(SignIn()), search: search, copiedID: copiedID,
    snapshotState: state, context: context, websiteSuggestions: websiteSuggestions)
  return AnyView(VaultView(model: model, state: state))
}
