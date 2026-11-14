// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MillCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MillCore", targets: ["MillCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "MillCore",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        // Self-test runner: `swift run MillCoreSelfTest`. Used instead of XCTest/Swift Testing because
        // the Command Line Tools alone ship neither the XCTest module nor the Testing macros.
        .executableTarget(
            name: "MillCoreSelfTest",
            dependencies: ["MillCore"]
        ),
        // `swift run millcheck status`: read-only check of a real machine through MillSession.
        .executableTarget(name: "millcheck", dependencies: ["MillCore"]),
    ]
)
