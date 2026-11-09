// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CrtApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "crt-smoke",       targets: ["CrtSmoke"]),
        .executable(name: "crt-sweep",       targets: ["CrtSweep"]),
        .executable(name: "crt-video-smoke", targets: ["CrtVideoSmoke"]),
        .executable(name: "crt-app",         targets: ["CrtApp"]),
    ],
    targets: [
        .target(
            name: "CrtAppBridge",
            path: "Sources/CrtAppBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
            ]
        ),
        // The Digital video stage's codec: per-pixel CPU work that runs
        // ~150× slower unoptimized, which would make debug builds (and the
        // dev hooks that run them) useless for judging it. So it's always
        // optimized; it has no dependencies to keep it that simple.
        .target(
            name: "CrtCodec",
            path: "Sources/CrtCodec",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(
            name: "CrtCore",
            dependencies: ["CrtAppBridge", "CrtCodec"],
            path: "Sources/CrtCore",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(
            name: "CrtSmoke",
            dependencies: ["CrtAppBridge", "CrtCore"],
            path: "Sources/CrtSmoke",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .executableTarget(
            name: "CrtSweep",
            dependencies: ["CrtAppBridge", "CrtCore"],
            path: "Sources/CrtSweep",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .executableTarget(
            name: "CrtVideoSmoke",
            dependencies: ["CrtAppBridge", "CrtCore"],
            path: "Sources/CrtVideoSmoke",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .testTarget(
            name: "CrtCoreTests",
            dependencies: ["CrtCore", "CrtAppBridge", "CrtCodec"],
            path: "Tests/CrtCoreTests"
        ),
        .executableTarget(
            name: "CrtApp",
            dependencies: ["CrtAppBridge", "CrtCore"],
            path: "Sources/CrtApp",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
    ]
)
