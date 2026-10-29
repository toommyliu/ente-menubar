import Foundation

struct UsageStore {
  let file: CacheStore

  init(cacheURL: URL) {
    file = CacheStore(url: cacheURL.deletingLastPathComponent().appending(path: "usage.json"))
  }

  func load() throws -> UsageHistory {
    guard let data = try file.load() else { return UsageHistory() }
    return try JSONDecoder().decode(UsageHistory.self, from: data)
  }

  func save(_ usage: UsageHistory) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try file.save(encoder.encode(usage))
  }

  func delete() throws { try file.delete() }
}
