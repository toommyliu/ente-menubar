import EnteBridge
import Foundation
import Testing

@testable import AppCore

struct CodeDiscoveryTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func everyTokenMustMatchAndFieldsRankBeforeFuzzy() {
    let codes = [
      discoveryCode("stage", "AWS", "staging"),
      discoveryCode("prod", "AWS", "production"),
      discoveryCode("other", "Awesome", "preview"),
      discoveryCode("note", "Other", "account", note: "AWS production"),
    ]
    #expect(rankedCodes(codes, query: "aws pr", now: now).map(\.id) == ["prod", "note", "other"])
    #expect(rankedCodes(codes, query: "  AWS   pr  ", now: now).map(\.id) == ["prod", "note", "other"])
    #expect(rankedCodes(codes, query: "aws nonexistent", now: now).map(\.id) == [])
    #expect(rankedCodes([discoveryCode("word", "My AWS"), discoveryCode("prefix", "AWS")],
      query: "aws", now: now).map(\.id) == ["prefix", "word"])
  }

  @Test func tagPrefixesNotesAndFuzzySubsequences() {
    let codes = [
      discoveryCode("github", "GitHub", tags: ["dev"]),
      discoveryCode("bank", "Bank", tags: ["Finance-work"]),
      discoveryCode("note", "Other", note: "finance approval"),
      discoveryCode("account", "Other", "ghost"),
      discoveryCode("trashed", "GitHub", trashed: true),
    ]
    #expect(rankedCodes(codes, query: "#finance", now: now).map(\.id) == ["bank"])
    #expect(rankedCodes(codes, query: "#FIN bank", now: now).map(\.id) == ["bank"])
    #expect(rankedCodes(codes, query: "gh", now: now).map(\.id) == ["account", "github"])
    #expect(rankedCodes(codes, query: "appr", now: now).map(\.id) == ["note"])
  }

  @Test func tiesUseUsageThenIssuerAccountAndID() {
    let codes = [
      discoveryCode("z", "GitHub", "z"), discoveryCode("b", "GitHub", "a"),
      discoveryCode("a", "GitHub", "a"), discoveryCode("recent", "GitHub", "work"),
    ]
    let usage = UsageHistory(codes: [
      "recent": CodeUsage(activity: UsageActivity(count: 3, lastUsedAt: now)),
      "z": CodeUsage(activity: UsageActivity(count: 4, lastUsedAt: now.addingTimeInterval(-7 * 86400))),
    ])
    #expect(rankedCodes(codes, query: "git", usage: usage, now: now).map(\.id) == ["recent", "z", "a", "b"])
  }

  @Test func usageDecaysAndLocalActivityReplacesSyncedSeed() {
    #expect(UsageActivity(count: 8, lastUsedAt: now.addingTimeInterval(-7 * 86400)).score(at: now) == 4)
    #expect(UsageActivity(count: 8, lastUsedAt: now.addingTimeInterval(86400)).score(at: now) == 8)
    let code = discoveryCode("seed", "GitHub", tapCount: 12, lastUsedAt: 1_700_000_000_000)
    var history = UsageHistory()
    #expect(history.activity(for: code).score(at: now) == 12)
    history.record(code, context: website("github.com"), at: now)
    #expect(history.codes["seed"]?.activity.count == 13)
    #expect(history.codes["seed"]?.contexts["github.com"]?.count == 1)
    let updated = discoveryCode("seed", "GitHub", tapCount: 100, lastUsedAt: 1_700_000_000_000)
    #expect(history.activity(for: updated).score(at: now) == 13)
  }

  @Test func contextUsesLearningThenDirectNamesThenCatalogAliases() {
    let codes = [discoveryCode("amazon", "Amazon"), discoveryCode("aws", "AWS"),
      discoveryCode("github", "GitHub"), discoveryCode("terminal", "Terminal")]
    #expect(contextMatches(codes, context: website("github.com"), usage: UsageHistory(), now: now).map(\.id) == ["github"])
    #expect(contextMatches(codes, context: website("console.aws.amazon.com"), usage: UsageHistory(), now: now).map(\.id) == ["aws", "amazon"])
    #expect(contextMatches(codes, context: website("unknown.example"), usage: UsageHistory(), now: now).map(\.id) == [])
    var learned = UsageHistory()
    learned.record(codes[1], context: website("login.example"), at: now)
    #expect(contextMatches(codes, context: website("login.example"), usage: learned, now: now).map(\.id) == [])
    learned.record(codes[1], context: website("login.example"), at: now)
    #expect(contextMatches(codes, context: website("login.example"), usage: learned, now: now).map(\.id) == ["aws"])
    let app = ForegroundContext(application: ApplicationContext(bundleID: "com.apple.Terminal", name: "Terminal"))
    learned.record(codes[2], context: app, at: now)
    #expect(contextMatches(codes, context: app, usage: learned, now: now).map(\.id) == ["terminal"])
    learned.record(codes[2], context: app, at: now)
    #expect(contextMatches(codes, context: app, usage: learned, now: now).map(\.id) == ["github"])
    #expect(contextMatches(codes, context: app, usage: UsageHistory(), now: now).map(\.id) == ["terminal"])
    let icon = ServiceIcon(source: .custom, slug: "aws", hex: nil)
    let catalog = IconCatalog(custom: ["amazonwebservices": icon, "aws": icon], simple: [:])
    #expect(contextMatches([discoveryCode("long", "Amazon Web Services")], context: website("console.aws.amazon.com"),
      usage: UsageHistory(), now: now, catalog: catalog).map(\.id) == ["long"])
  }

  @Test func sectionsDeduplicateUpperRowsAndShowCompleteContextResults() {
    let codes = [
      discoveryCode("gh1", "GitHub", "a", pinned: true), discoveryCode("gh2", "GitHub", "b"),
      discoveryCode("gh3", "GitHub", "c"), discoveryCode("gh4", "GitHub", "d"),
      discoveryCode("pin", "Google", pinned: true), discoveryCode("frequent", "AWS", tapCount: 8, lastUsedAt: 1_700_000_000_000),
      discoveryCode("extra", "Slack"),
    ]
    let rows = discoveryRows(codes: codes, query: "", usage: UsageHistory(), context: website("github.com"),
      websiteSuggestions: true, allExpanded: false, now: now)
    #expect(rows.compactMap(\.code).map(\.id) == ["gh1", "gh2", "gh3", "pin", "frequent", "gh4", "extra"])
    #expect(!rows.contains { $0.id == .header(.frequent) })
    #expect(rows.contains { $0.id == .header(.other) })
    #expect(rows.contains { if case .more(1, "github.com") = $0 { true } else { false } })
    let results = discoveryRows(codes: codes, query: "github.com", usage: UsageHistory(), context: website("github.com"),
      websiteSuggestions: true, allExpanded: false, now: now, contextSearch: true)
    #expect(results.compactMap(\.code).map(\.id) == ["gh1", "gh2", "gh3", "gh4"])
  }

  @Test func allCodesThresholdCountsVisibleCodesAndOptInIsSelectable() {
    let codes = (1...16).map { discoveryCode("\($0)", String(format: "Service %02d", $0)) }
    func rows(_ input: [CodeView], expanded: Bool = false) -> [DiscoveryRow] {
      discoveryRows(codes: input, query: "", usage: UsageHistory(), context: website("github.com"),
        websiteSuggestions: false, allExpanded: expanded, now: now)
    }
    #expect(rows(Array(codes.prefix(15))).compactMap(\.code).count == 15)
    #expect(rows(Array(codes.prefix(15))).contains { $0.id == .header(.all) })
    #expect(rows(codes).map(\.id).suffix(1) == [.showAll])
    #expect(rows(codes, expanded: true).compactMap(\.code).count == 16)
    #expect(rows(Array(codes.prefix(15)) + [discoveryCode("trash", "Trash", trashed: true)]).compactMap(\.code).count == 15)
    #expect(rows(codes).filter(\.selectable).map(\.id).first == .websiteSetup)
    let used = [discoveryCode("used", "Zulip", tapCount: 3, lastUsedAt: 1_700_000_000_000)] + codes
    #expect(rows(used).compactMap(\.code).map(\.id) == ["used"])
    #expect(rows(used, expanded: true).compactMap(\.code).map(\.id).filter { $0 == "used" }.count == 1)
    #expect(rows(used, expanded: true).compactMap(\.code).count == 17)
  }

  @Test func usageFileRoundTripsWithPrivatePermissionsNextToCache() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "usage-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UsageStore(cacheURL: directory.appending(path: "cache.bin"))
    var history = UsageHistory()
    history.record(discoveryCode("id", "GitHub"), context: website("github.com"), at: now)
    try store.save(history)
    let restored = try store.load()
    #expect(restored.codes["id"]?.activity == UsageActivity(count: 1, lastUsedAt: now))
    #expect(restored.codes["id"]?.contexts["github.com"]?.count == 1)
    #expect(store.file.url.path == directory.appending(path: "usage.json").path)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.file.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try store.delete()
    #expect(try store.load().codes == [:])
  }

  private func website(_ host: String) -> ForegroundContext {
    ForegroundContext(application: ApplicationContext(bundleID: "net.imput.helium", name: "Helium"), hostname: host)
  }
}

func discoveryCode(
  _ id: String, _ issuer: String, _ account: String = "", pinned: Bool = false, trashed: Bool = false,
  tags: [String] = [], note: String = "", tapCount: Int64 = 0, lastUsedAt: Int64 = 0
) -> CodeView {
  CodeView(id: id, issuer: issuer, account: account, kind: .totp, current: "123456", next: "234567",
    periodSecs: 30, remainingMs: 15000,
    display: Display(pinned: pinned, trashed: trashed, tags: tags, note: note, iconSrc: "", iconId: "",
      tapCount: tapCount, lastUsedAt: lastUsedAt))
}
