// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift Package Manager required to build this package.

import PackageDescription

let package = Package(
    name: "VocaMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "VocaMac",
            targets: ["VocaMac"]
        )
    ],
    dependencies: [
        // WhisperKit — local, on-device speech-to-text powered by CoreML
        // https://github.com/argmaxinc/WhisperKit
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.4"),
        // FluidAudio — NVIDIA Parakeet TDT models as CoreML on the Neural Engine
        // https://github.com/FluidInference/FluidAudio
        // Held to 0.15.x: this is the version the engine is tested against, and
        // the APIs used here (AsrManager.loadModels, throwing TdtDecoderState,
        // the transcribe language hint) do not all exist in earlier releases.
        // FluidAudio is pre-1.0, so minor bumps may break the build.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5")),
        // sherpa-onnx — specialized ONNX models (Moonshine, SenseVoice,
        // GigaAM, Canary) via ONNX Runtime, CPU-only.
        // Pin the release and its matching binary xcframework for reproducible builds.
        .package(
            url: "https://github.com/k2-fsa/sherpa-onnx",
            exact: "1.13.7"
        ),
    ],
    targets: [
        // Objective-C helpers used by the Swift app.
        .target(
            name: "VocaMacObjC",
            path: "Sources/VocaMacObjC",
            publicHeadersPath: "include"
        ),
        // Main application target
        .executableTarget(
            name: "VocaMac",
            dependencies: [
                "VocaMacObjC",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
            ],
            path: "Sources/VocaMac",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        // Test target
        .testTarget(
            name: "VocaMacTests",
            dependencies: ["VocaMac"],
            path: "Tests/VocaMacTests",
            exclude: ["Fixtures"]
        )
    ]
)
