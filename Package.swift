// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ApoloEngine",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "ApoloEngine",
            targets: ["ApoloEngine"]
        ),
    ],
    dependencies: [
        // Temporary A1 release-candidate consumer QA only.
        // Pin the exact reviewed commit; do not track a moving branch.
        // Keep the Aether* product names until a separately reviewed migration.
        .package(
            url: "https://github.com/Mosas123/ApoloFFmpeg",
            revision: "0760ac161498ced0c63d6057abf52cd3432c5086"
        ),
    ],
    targets: [
        .target(
            name: "ApoloEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "ApoloFFmpeg"),
                .product(name: "AetherLibavcodec", package: "ApoloFFmpeg"),
                .product(name: "AetherLibavformat", package: "ApoloFFmpeg"),
                .product(name: "AetherLibavutil", package: "ApoloFFmpeg"),
                .product(name: "AetherLibswresample", package: "ApoloFFmpeg"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("MediaPlayer"),
            ]
        ),
        .testTarget(
            name: "ApoloEngineTests",
            dependencies: [
                "ApoloEngine",
                .product(name: "AetherLibavcodec", package: "ApoloFFmpeg"),
                .product(name: "AetherLibavfilter", package: "ApoloFFmpeg"),
                .product(name: "AetherLibavformat", package: "ApoloFFmpeg"),
                .product(name: "AetherLibavutil", package: "ApoloFFmpeg"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
