// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            revision: "97d09fd9790393579d2834e2bc098deb3e26bc06"
        ),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.0.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .target(
            name: "TranscriberCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "Transcriber",
            dependencies: [
                "TranscriberCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "TranscriberCLI",
            dependencies: ["TranscriberCore"]
        ),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"]
        ),
        // Тесты самого приложения: стопка карточек живёт окнами, и её поведение
        // (вытеснение, освобождение окна) проверяется только здесь.
        .testTarget(
            name: "TranscriberAppTests",
            dependencies: ["Transcriber"]
        ),
    ]
)
