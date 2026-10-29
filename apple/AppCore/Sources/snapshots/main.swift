import AppCore
import AppKit
import Foundation

@main struct Snapshots {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    guard CommandLine.arguments.count == 2 else {
      throw CocoaError(.fileNoSuchFile)
    }
    try renderSnapshots(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
  }
}
