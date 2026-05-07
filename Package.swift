// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NotchIsland", targets: ["NotchIsland"])
    ],
    targets: [
        .executableTarget(
            name: "NotchIsland",
            path: ".",
            exclude: [
                "README.md",
                "scripts",
                "dist"
            ],
            sources: [
                "Sources/NotchIsland/main.swift"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("MediaPlayer")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
