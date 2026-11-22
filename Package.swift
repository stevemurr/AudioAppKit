// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "AudioAppKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AudioAppKit", targets: ["AudioAppKit"]),
        .library(name: "AudioAppControls", targets: ["AudioAppControls"]),
        .library(name: "AudioAppPlugin", targets: ["AudioAppPlugin"]),
        .library(name: "AudioAppTesting", targets: ["AudioAppTesting"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0")
    ],
    targets: [
        .macro(name: "AudioAppMacros", dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
        ]),
        .target(name: "CAudioAppSupport"),
        .target(name: "AudioAppCore"),
        .target(name: "AudioAppRealtime", dependencies: ["CAudioAppSupport"]),
        .target(name: "AudioAppProcessing", dependencies: ["AudioAppCore", "AudioAppRealtime", "AudioAppMacros"]),
        .target(name: "AudioAppDSP", dependencies: ["AudioAppCore", "AudioAppRealtime", "AudioAppProcessing"]),
        .target(name: "AudioAppMetering", dependencies: ["AudioAppCore", "AudioAppRealtime", "AudioAppProcessing", "AudioAppDSP"]),
        .target(name: "AudioAppRenderAhead", dependencies: ["AudioAppCore", "AudioAppRealtime", "AudioAppProcessing"]),
        .target(name: "AudioAppIO", dependencies: ["AudioAppCore", "AudioAppRealtime", "AudioAppProcessing", "AudioAppDSP", "AudioAppRenderAhead", "CAudioAppSupport"]),
        .target(name: "AudioAppKit", dependencies: ["AudioAppCore", "AudioAppRealtime", "AudioAppProcessing", "AudioAppDSP",
                                                    "AudioAppMetering", "AudioAppRenderAhead", "AudioAppIO"]),
        .target(name: "AudioAppControls", dependencies: ["AudioAppKit"]),
        .target(name: "AudioAppPlugin", dependencies: ["AudioAppKit"]),
        .target(name: "AudioAppTesting", dependencies: ["AudioAppKit", "CAudioAppSupport"]),
        .testTarget(name: "AudioAppKitTests", dependencies: ["AudioAppKit", "AudioAppControls", "AudioAppPlugin", "AudioAppTesting"])
    ],
    swiftLanguageModes: [.v6]
)
