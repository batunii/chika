// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChikaCore",
    // String form: the `.v15` enum case needs tools-version 6.0, and the contract pins 5.9.
    platforms: [.macOS("15.0")],
    products: [.library(name: "ChikaCore", targets: ["ChikaCore"])],
    targets: [
        .target(name: "ChikaCore"),
        .testTarget(name: "ChikaCoreTests", dependencies: ["ChikaCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
