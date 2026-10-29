// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AppCore",
  platforms: [.macOS(.v14)],
  products: [.library(name: "AppCore", targets: ["AppCore"])],
  dependencies: [.package(path: "../EnteBridge")],
  targets: [
    .target(name: "AppCore", dependencies: ["EnteBridge"], resources: [.copy("GeneratedIcons")]),
    .executableTarget(name: "snapshots", dependencies: ["AppCore"]),
    .executableTarget(name: "context-check", dependencies: ["AppCore"]),
    .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "EnteBridge"]),
  ]
)
