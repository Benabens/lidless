// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lidless",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LidlessCore", targets: ["LidlessCore"]),
        .executable(name: "Lidless", targets: ["Lidless"]),
        .executable(name: "lidless-hook", targets: ["lidless-hook"]),
    ],
    targets: [
        // Pure logic: no AppKit, fully unit-tested.
        .target(name: "LidlessCore"),
        // Menu bar app (AppKit + SwiftUI, LSUIElement).
        .executableTarget(name: "Lidless", dependencies: ["LidlessCore"]),
        // Tiny executable invoked by the agents' hooks.
        .executableTarget(name: "lidless-hook", dependencies: ["LidlessCore"]),
        // Depends on lidless-hook so the tests can run the real executable.
        .testTarget(name: "LidlessCoreTests", dependencies: ["LidlessCore", "lidless-hook"]),
    ]
)
