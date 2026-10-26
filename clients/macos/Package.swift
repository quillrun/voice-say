// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceSay",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "VoiceSay", targets: ["VoiceSay"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceSay",
            path: "VoiceSay",
            exclude: ["Info.plist"],
            resources: [],
            swiftSettings: [
                // Swift 6 language mode (strict concurrency). Explicit rather
                // than relying on the tools-version >=6 default, so intent is
                // self-documenting.
                .swiftLanguageMode(.v6)
            ]
        ),
        // Swift Testing target (Xcode 26.5 ships the Testing library). Reaches
        // the executable's internal symbols via `@testable import VoiceSay`.
        .testTarget(
            name: "VoiceSayTests",
            dependencies: ["VoiceSay"],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
