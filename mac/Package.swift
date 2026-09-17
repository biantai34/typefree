// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Typefree",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "VoicePolishCore"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Typefree",
            dependencies: [
                .product(name: "VoicePolishCore", package: "VoicePolishCore"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            exclude: [
                "record-start.wav",
                "record-stop.wav",
                "statusbar-icon.png",
                "statusbar-icon@2x.png"
            ]
        )
    ]
)
