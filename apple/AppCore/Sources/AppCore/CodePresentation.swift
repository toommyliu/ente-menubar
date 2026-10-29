import EnteBridge
import Foundation

struct CodePresentation {
  let text: String
  let accessibilityLabel: String

  init(_ code: String, hidden: Bool) {
    let value = hidden ? String(repeating: "•", count: code.count) : code
    if code.allSatisfy(\.isNumber), code.count == 6 || code.count == 8 {
      let half = code.count / 2
      text = "\(value.prefix(half)) \(value.suffix(half))"
    } else {
      text = value
    }
    accessibilityLabel = hidden ? "hidden code" : text
  }
}

struct CodeTiming {
  let code: CodeView
  var isExpiring: Bool { code.remainingMs <= 5000 }

  func remaining(at date: Date, sampledAt: Date) -> Double {
    max(0, Double(code.remainingMs) / 1000 - max(0, date.timeIntervalSince(sampledAt)))
  }

  static func selected(in rows: [DiscoveryRow], selection: DiscoveryRowID?) -> CodeTiming? {
    let code: CodeView?
    if let selection {
      code = rows.first { $0.id == selection }?.code
    } else {
      code = rows.compactMap(\.code).first { $0.kind != .hotp }
    }
    guard let code, code.kind != .hotp else { return nil }
    return CodeTiming(code: code)
  }
}
