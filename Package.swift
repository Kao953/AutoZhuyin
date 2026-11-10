// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoZhuyin",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AutoZhuyin", targets: ["AutoZhuyin"]),
        .library(name: "AutoZhuyinCore", targets: ["AutoZhuyinCore"]),
    ],
    targets: [
        // Pure logic: Zhuyin parsing, English/Zhuyin classification, conversion.
        // No AppKit dependency, so it can be unit-tested with `swift test`.
        .target(name: "AutoZhuyinCore"),
        // The InputMethodKit server process (packaged into a .app by scripts/build.sh).
        .executableTarget(
            name: "AutoZhuyin",
            dependencies: ["AutoZhuyinCore"],
            linkerSettings: [.linkedFramework("InputMethodKit"), .linkedFramework("Cocoa")]
        ),
        .testTarget(
            name: "AutoZhuyinCoreTests",
            dependencies: ["AutoZhuyinCore"]
        ),
    ]
)
