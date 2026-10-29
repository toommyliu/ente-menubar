// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnteBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EnteBridge", targets: ["EnteBridge"]),
        .executable(name: "smoke", targets: ["smoke"])
    ],
    targets: [
        .binaryTarget(name: "EnteBridgeFFI", path: "Frameworks/EnteBridgeFFI.xcframework"),
        .target(
            name: "EnteBridge",
            dependencies: ["EnteBridgeFFI"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("resolv")
            ]
        ),
        .executableTarget(name: "smoke", dependencies: ["EnteBridge"])
    ]
)
