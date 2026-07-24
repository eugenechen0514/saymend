// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Saymend",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/ddddxxx/SwiftyOpenCC", from: "2.0.0-beta"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SaymendCore",
            dependencies: [
                .product(name: "OpenCC", package: "SwiftyOpenCC"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SaymendApp",
            dependencies: ["SaymendCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SaymendCoreTests",
            dependencies: ["SaymendCore"],
            resources: [
                .copy("Fixtures/CoreMode/golden-default.follow-speech.json"),
                .copy("Fixtures/CoreMode/golden-default.zh-TW.json"),
                .copy("Fixtures/CoreMode/golden-default.zh-CN.json"),
                .copy("Fixtures/CoreMode/golden-default.en.json"),
                .copy("Fixtures/Adversarial/envelope-corpus.json"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SaymendAppTests",
            dependencies: ["SaymendApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
