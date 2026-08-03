// swift-tools-version: 6.2
import PackageDescription

// The screenplay engine: parsing, linting, pagination, PDF layout, metadata,
// and Highland import. Deliberately free of AppKit and SwiftUI so the whole
// engine is testable with `swift test` in seconds, without Xcode or a VM.
//
// Zero external dependencies. The one thing that would tempt a dependency —
// reading the zip inside a `.highland` — is ~180 lines against the system
// `Compression` framework. Check here before adding a first one.
let package = Package(
    name: "FountainKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "FountainKit", targets: ["FountainKit"]),
        .executable(name: "fountain-migrate", targets: ["fountain-migrate"])
    ],
    targets: [
        .target(
            name: "FountainKit",
            path: "Sources/FountainKit",
            // Swift 5 language mode, matching the app target. The editor
            // surface ported from topside is written against it, and nothing
            // here needs strict concurrency checking to be correct.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "fountain-migrate",
            dependencies: ["FountainKit"],
            path: "Sources/fountain-migrate",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FountainKitTests",
            dependencies: ["FountainKit"],
            path: "Tests/FountainKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
