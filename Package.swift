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
        .package(
            url: "https://github.com/superuser404notfound/FFmpegBuild",
            .upToNextMinor(from: "3.15.0")
        ),
    ],
    targets: [
        .target(
            name: "ApoloEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "AetherLibavcodec", package: "FFmpegBuild"),
                .product(name: "AetherLibavformat", package: "FFmpegBuild"),
                .product(name: "AetherLibavutil", package: "FFmpegBuild"),
                .product(name: "AetherLibswresample", package: "FFmpegBuild"),
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
                .product(name: "AetherLibavutil", package: "FFmpegBuild"),
            ]
        ),
    ]
)
