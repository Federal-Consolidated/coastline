// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MillCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MillCore", targets: ["MillCore"]),
    ],
    targets: [
        .target(name: "MillCore"),
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
