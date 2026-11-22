// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioAppKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AudioAppKit", targets: ["AudioAppKit"]),
        .library(name: "AudioAppTesting", targets: ["AudioAppTesting"])
    ],
    targets: [
        .target(name: "CAudioAppSupport"),
        .target(name: "AudioAppCore"),
        .target(name: "AudioAppRealtime", dependencies: ["CAudioAppSupport"]),
        .target(name: "AudioAppProcessing", dependencies: ["AudioAppCore", "AudioAppRealtime"]),
        .target(name: "AudioAppDSP", dependencies: ["AudioAppCore", "AudioAppRealtime", "AudioAppProcessing"]),
        .target(name: "AudioAppKit", dependencies: ["AudioAppCore", "AudioAppRealtime", "AudioAppProcessing", "AudioAppDSP"]),
        .target(name: "AudioAppTesting", dependencies: ["AudioAppKit", "CAudioAppSupport"]),
        .testTarget(name: "AudioAppKitTests", dependencies: ["AudioAppKit", "AudioAppTesting"])
    ],
    swiftLanguageModes: [.v6]
)
