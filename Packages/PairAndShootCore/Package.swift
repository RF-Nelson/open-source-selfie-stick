// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PairAndShootCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PairAndShootCore", targets: ["PairAndShootCore"]),
    ],
    targets: [
        .target(name: "PairAndShootCore"),
        .testTarget(name: "PairAndShootCoreTests", dependencies: ["PairAndShootCore"]),
    ],
    swiftLanguageModes: [.v6]
)
