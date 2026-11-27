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
        // 本機控制介面（unix socket 協定、NDJSON、CLI 邏輯）。刻意零相依：`saymend` CLI 只連它，
        // 不拖進 WhisperKit／GRDB／OpenCC，啟動才會快。
        .target(
            name: "SaymendControl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `saymend` CLI：打包時放進 Saymend.app/Contents/Helpers/（見 Scripts/make-app.sh）。
        // 不叫 `saymend` 是因為 macOS 檔案系統不分大小寫，會跟 app 主程式 `Saymend` 撞名。
        .executableTarget(
            name: "SaymendCLI",
            dependencies: ["SaymendControl"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SaymendCore",
            dependencies: [
                "SaymendControl",
                .product(name: "OpenCC", package: "SwiftyOpenCC"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SaymendApp",
            dependencies: ["SaymendCore", "SaymendControl"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SaymendCoreTests",
            dependencies: ["SaymendCore"],
            // 假的 ssh（遠端橋接測試以 #filePath 直接執行它，不當成 bundle 資源）
            exclude: ["Fixtures/Remote"],
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
            name: "SaymendControlTests",
            dependencies: ["SaymendControl"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SaymendAppTests",
            dependencies: ["SaymendApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
