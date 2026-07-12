// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Speeckink",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/ddddxxx/SwiftyOpenCC", from: "2.0.0-beta"),
    ],
    targets: [
        .target(
            name: "SpeeckinkCore",
            dependencies: [.product(name: "OpenCC", package: "SwiftyOpenCC")],
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
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
