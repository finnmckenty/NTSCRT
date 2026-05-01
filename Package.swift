// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CrtApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "crt-smoke", targets: ["CrtSmoke"]),
        // crt-app SwiftUI executable added in Phase 2.
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
        .executableTarget(
            name: "CrtSmoke",
            dependencies: ["CrtAppBridge"],
            path: "Sources/CrtSmoke",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreServices"),
            ]
        ),
    ]
)
