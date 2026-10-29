// swift-tools-version: 6.1
import PackageDescription

/// Language settings for every target: Swift 6 mode (complete concurrency checking)
/// plus the upcoming features that make the code stricter.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "gcpapi-sync-swift",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "GCPAPISync", targets: ["GCPAPISync"]),
        .executable(name: "gcpapi", targets: ["gcpapi"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0"),
    ],
    targets: [
        .target(
            name: "GCPAPISync",
            dependencies: [.product(name: "Logging", package: "swift-log")],
            swiftSettings: strict
        ),
        .target(
            name: "GCPAPICLI",
            dependencies: [
                "GCPAPISync",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(name: "gcpapi", dependencies: ["GCPAPICLI"], swiftSettings: strict),
        .target(name: "ToolSupport", path: "Tools/ToolSupport", swiftSettings: strict),
        .executableTarget(
            name: "generate-models",
            dependencies: [
                "ToolSupport", .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/GenerateModels",
            swiftSettings: strict
        ),
        .executableTarget(
            name: "bump-version",
            dependencies: [
                "ToolSupport", .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/BumpVersion",
            swiftSettings: strict
        ),
        .executableTarget(
            name: "scrub-fixture",
            dependencies: [
                "ToolSupport", .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/ScrubFixture",
            swiftSettings: strict
        ),
        .executableTarget(
            name: "check-coverage",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Tools/CheckCoverage",
            swiftSettings: strict
        ),
        .testTarget(
            name: "GCPAPISyncTests",
            dependencies: [
                "GCPAPISync", "GCPAPICLI", .product(name: "Logging", package: "swift-log"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
        .testTarget(name: "LiveTests", dependencies: ["GCPAPISync"], swiftSettings: strict),
    ]
)
