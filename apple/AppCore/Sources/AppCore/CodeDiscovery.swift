import EnteBridge
import Foundation

struct UsageActivity: Codable, Equatable, Sendable {
  var count: Int64
  var lastUsedAt: Date

  func score(at now: Date) -> Double {
    Double(max(0, count)) / (1 + max(0, now.timeIntervalSince(lastUsedAt)) / (86400 * 7))
  }
}

struct CodeUsage: Codable, Equatable, Sendable {
  var activity: UsageActivity
  var contexts: [String: UsageActivity] = [:]
}

struct UsageHistory: Codable, Equatable, Sendable {
  var codes: [String: CodeUsage] = [:]

  func activity(for code: CodeView) -> UsageActivity {
    codes[code.id]?.activity ?? UsageActivity(
      count: max(0, code.display.tapCount),
      lastUsedAt: Date(timeIntervalSince1970: Double(code.display.lastUsedAt) / 1000))
  }

  mutating func record(_ code: CodeView, context: ForegroundContext?, at now: Date) {
    var usage = codes[code.id] ?? CodeUsage(activity: activity(for: code))
    usage.activity = UsageActivity(count: usage.activity.count + 1, lastUsedAt: now)
    if let key = context?.key {
      usage.contexts[key] = UsageActivity(count: (usage.contexts[key]?.count ?? 0) + 1, lastUsedAt: now)
    }
    codes[code.id] = usage
  }
}

public struct ApplicationContext: Equatable, Sendable {
  public let bundleID: String
  public let name: String

  public init(bundleID: String, name: String) {
    self.bundleID = bundleID
    self.name = name
  }

  public var isBrowser: Bool {
    Self.browserBundleIDs.contains(bundleID)
  }

  static let browserBundleIDs: Set<String> = [
    "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "net.imput.helium",
    "com.microsoft.edgemac", "company.thebrowser.Browser",
  ]
}

public struct ForegroundContext: Equatable, Sendable {
  public let application: ApplicationContext
  public let hostname: String?

  public init(application: ApplicationContext, hostname: String? = nil) {
    self.application = application
    self.hostname = hostname?.lowercased()
  }

  var key: String { hostname ?? application.bundleID }
  var label: String { hostname ?? application.name }
  var candidates: [String] { hostname?.components(separatedBy: ".") ?? [application.name] }
}

func normalizedIssuer(_ value: String) -> String {
  String(value.lowercased().filter { $0.isLetter || $0.isNumber })
}

func codeAlphabeticalOrder(_ lhs: CodeView, _ rhs: CodeView) -> Bool {
  for (left, right) in [(lhs.issuer, rhs.issuer), (lhs.account, rhs.account)] {
    let order = left.localizedCaseInsensitiveCompare(right)
    if order != .orderedSame { return order == .orderedAscending }
  }
  return lhs.id < rhs.id
}

func rankedCodes(
  _ codes: [CodeView], query: String, usage: UsageHistory = UsageHistory(), now: Date
) -> [CodeView] {
  let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
  let scored = codes.filter { !$0.display.trashed }.compactMap { code -> (CodeView, Int)? in
    let issuer = code.issuer.lowercased()
    let words = ([code.issuer, code.account, code.display.note] + code.display.tags)
      .joined(separator: " ").lowercased().split { !$0.isLetter && !$0.isNumber }
    let fuzzyText = normalizedIssuer(code.issuer + code.account)
    var score = 0
    for token in tokens {
      if token.hasPrefix("#") {
        guard code.display.tags.contains(where: { $0.lowercased().hasPrefix(String(token.dropFirst())) })
        else { return nil }
      } else if issuer.hasPrefix(token) {
        score += 3
      } else if words.contains(where: { $0.hasPrefix(token) }) {
        score += 2
      } else {
        var remainder = token[...]
        for character in fuzzyText where remainder.first == character { remainder.removeFirst() }
        guard remainder.isEmpty else { return nil }
        score += 1
      }
    }
    return (code, score)
  }
  return scored.sorted { lhs, rhs in
    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
    if !tokens.isEmpty {
      let left = usage.activity(for: lhs.0).score(at: now)
      let right = usage.activity(for: rhs.0).score(at: now)
      if left != right { return left > right }
    }
    return codeAlphabeticalOrder(lhs.0, rhs.0)
  }.map(\.0)
}

func contextMatches(
  _ codes: [CodeView], context: ForegroundContext?, usage: UsageHistory, now: Date,
  catalog: IconCatalog = .bundled
) -> [CodeView] {
  guard let context else { return [] }
  let visible = codes.filter { !$0.display.trashed }
  let learned = visible.compactMap { code -> (CodeView, Double)? in
    guard let activity = usage.codes[code.id]?.contexts[context.key] else { return nil }
    return (code, activity.score(at: now))
  }
  if !learned.isEmpty {
    return learned.sorted {
      $0.1 == $1.1 ? codeAlphabeticalOrder($0.0, $1.0) : $0.1 > $1.1
    }.map(\.0)
  }
  let candidates = context.candidates.map(normalizedIssuer).filter { !$0.isEmpty }
  func orderedMatches(_ match: (CodeView, String) -> Bool) -> [CodeView] {
    let matches = visible.compactMap { code -> (CodeView, Int)? in
      guard let index = candidates.firstIndex(where: { match(code, $0) }) else { return nil }
      return (code, index)
    }
    return matches.sorted {
      if $0.1 != $1.1 { return $0.1 < $1.1 }
      let left = usage.activity(for: $0.0).score(at: now)
      let right = usage.activity(for: $1.0).score(at: now)
      return left == right ? codeAlphabeticalOrder($0.0, $1.0) : left > right
    }.map(\.0)
  }
  let direct = orderedMatches { normalizedIssuer($0.issuer) == $1 }
  if !direct.isEmpty { return direct }
  return orderedMatches { code, candidate in
    guard let identity = catalog.contextIdentity(for: code.issuer) else { return false }
    return identity == catalog.contextIdentity(for: candidate)
  }
}

enum CodeSection: String, Hashable {
  case suggested = "Suggested", pinned = "Pinned", frequent = "Frequent", all = "All codes"
  case results = "Results"
}

enum DiscoveryRowID: Hashable {
  case header(CodeSection), code(CodeSection, String), more, showAll, enableWebsites
}

enum DiscoveryRow: Identifiable {
  case header(CodeSection, String?)
  case code(CodeSection, CodeView)
  case more(Int, String)
  case showAll(Int)
  case enableWebsites

  var id: DiscoveryRowID {
    switch self {
    case .header(let section, _): .header(section)
    case .code(let section, let code): .code(section, code.id)
    case .more: .more
    case .showAll: .showAll
    case .enableWebsites: .enableWebsites
    }
  }

  var selectable: Bool {
    if case .header = self { return false }
    return true
  }

  var code: CodeView? {
    if case .code(_, let code) = self { return code }
    return nil
  }
}

func discoveryRows(
  codes: [CodeView], query: String, usage: UsageHistory, context: ForegroundContext?,
  websiteSuggestions: Bool, allExpanded: Bool, now: Date,
  contextSearch: Bool = false
) -> [DiscoveryRow] {
  let visible = codes.filter { !$0.display.trashed }
  let suggestions = contextMatches(visible, context: context, usage: usage, now: now)
  if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    let results = contextSearch ? suggestions : rankedCodes(visible, query: query, usage: usage, now: now)
    guard !results.isEmpty else { return [] }
    return [.header(.results, "\(results.count) \(results.count == 1 ? "match" : "matches")")]
      + results.map { .code(.results, $0) }
  }
  var rows: [DiscoveryRow] = []
  var shown: Set<String> = []
  if !suggestions.isEmpty || (context?.application.isBrowser == true && !websiteSuggestions) {
    rows.append(.header(.suggested, context.map { "for \($0.label)" }))
    for code in suggestions.prefix(3) {
      rows.append(.code(.suggested, code))
      shown.insert(code.id)
    }
    if suggestions.count > 3, let context { rows.append(.more(suggestions.count - 3, context.label)) }
    if context?.application.isBrowser == true && !websiteSuggestions { rows.append(.enableWebsites) }
  }
  let pinned = visible.filter { $0.display.pinned && !shown.contains($0.id) }.sorted(by: codeAlphabeticalOrder)
  if !pinned.isEmpty {
    rows.append(.header(.pinned, nil))
    for code in pinned {
      rows.append(.code(.pinned, code))
      shown.insert(code.id)
    }
  }
  let frequent = visible.filter { !shown.contains($0.id) }.sorted {
    let left = usage.activity(for: $0).score(at: now)
    let right = usage.activity(for: $1).score(at: now)
    return left == right ? codeAlphabeticalOrder($0, $1) : left > right
  }.prefix(4)
  if !frequent.isEmpty {
    rows.append(.header(.frequent, nil))
    rows += frequent.map { .code(.frequent, $0) }
  }
  if !visible.isEmpty {
    if visible.count > 15 && !allExpanded {
      rows.append(.showAll(visible.count))
    } else {
      rows.append(.header(.all, nil))
      rows += visible.sorted(by: codeAlphabeticalOrder).map { .code(.all, $0) }
    }
  }
  return rows
}
