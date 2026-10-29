import Foundation

struct ServiceIcon: Decodable, Equatable, Hashable, Sendable {
  enum Source: String, Decodable, Sendable {
    case custom
    case simple
  }

  let source: Source
  let slug: String
  let hex: String?

  var key: String { "\(source.rawValue)-\(slug)" }
}

struct IconRequest: Equatable {
  let issuer: String
  let iconSrc: String
  let iconID: String
}

struct IconCatalog: Decodable, Sendable {
  let custom: [String: ServiceIcon]
  let simple: [String: ServiceIcon]

  static let bundled: IconCatalog = {
    guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json",
                                      subdirectory: "GeneratedIcons"),
      let data = try? Data(contentsOf: url),
      let catalog = try? JSONDecoder().decode(IconCatalog.self, from: data)
    else { preconditionFailure("Run scripts/icons.sh before building AppCore") }
    return catalog
  }()

  func match(_ request: IconRequest) -> ServiceIcon? {
    let explicit = !request.iconSrc.isEmpty && !request.iconID.isEmpty
    let provider = explicit ? request.iconID : request.issuer
    let title = (provider.removingPercentEncoding ?? provider)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "").lowercased()
    var candidates = [title]
    for separator: Character in ["(", "."] {
      if let index = title.firstIndex(of: separator) {
        candidates.append(String(title[..<index]))
      }
    }
    for candidate in candidates {
      if let icon = custom[candidate] ?? simple[candidate] { return icon }
    }
    return nil
  }
}

struct IconBrandColor: Equatable {
  let red: Double
  let green: Double
  let blue: Double

  init(hex: String) {
    let value = UInt32(hex, radix: 16) ?? 0
    red = Double((value >> 16) & 255) / 255
    green = Double((value >> 8) & 255) / 255
    blue = Double(value & 255) / 255
  }

  var usesBlackGlyph: Bool {
    let linear = [red, green, blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    let luminance = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    return (luminance + 0.05) / 0.05 > 1.05 / (luminance + 0.05)
  }
}
