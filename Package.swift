// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftRDP",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "SwiftRDPCore", targets: ["SwiftRDPCore"]),
        .executable(name: "swift-rdp", targets: ["SwiftRDPServer"]),
        .executable(name: "SwiftRDPApp", targets: ["SwiftRDPApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
    ],
    targets: [
        .target(
            name: "SwiftRDPObjC",
            path: "Sources/SwiftRDPObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SwiftRDPCore",
            dependencies: [
                "SwiftRDPObjC",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources/SwiftRDPCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ColorSync"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "SwiftRDPServer",
            dependencies: ["SwiftRDPCore"],
            path: "Sources/SwiftRDPServer"
        ),
        .executableTarget(
            name: "SwiftRDPApp",
            dependencies: [
                "SwiftRDPCore",
            ],
            path: "Sources/SwiftRDPApp",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/swiftrdp.png"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "SwiftRDPCoreTests",
            dependencies: ["SwiftRDPCore"],
            path: "Tests/SwiftRDPCoreTests",
            resources: [
                .copy("Fixtures/real-video-stats.log"),
            ]
        ),
    ]
)
