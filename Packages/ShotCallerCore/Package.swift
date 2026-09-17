// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShotCallerCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ShotCallerCore", targets: ["ShotCallerCore"]),
    ],
    targets: [
        .target(name: "ShotCallerCore"),
        .testTarget(name: "ShotCallerCoreTests", dependencies: ["ShotCallerCore"]),
    ],
    swiftLanguageModes: [.v6]
)
