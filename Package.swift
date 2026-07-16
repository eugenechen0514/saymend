// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Speeckink",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/ddddxxx/SwiftyOpenCC", from: "2.0.0-beta"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "SpeeckinkCore",
            dependencies: [
                .product(name: "OpenCC", package: "SwiftyOpenCC"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SpeeckinkApp",
            dependencies: ["SpeeckinkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpeeckinkCoreTests",
            dependencies: ["SpeeckinkCore"],
            resources: [
                .copy("Fixtures/CoreMode/golden-default.follow-speech.json"),
                .copy("Fixtures/CoreMode/golden-default.zh-TW.json"),
                .copy("Fixtures/CoreMode/golden-default.zh-CN.json"),
                .copy("Fixtures/CoreMode/golden-default.en.json"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpeeckinkAppTests",
            dependencies: ["SpeeckinkApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
