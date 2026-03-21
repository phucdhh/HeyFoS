// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HeyFoS",
    platforms: [
        .macOS(.v14) // Requires macOS Sonoma for Metal 3 and latest Swift features
    ],
    products: [
        // Core processing library
        .library(
            name: "HeyFoSCore",
            targets: ["HeyFoSCore"]
        ),
        // CLI tool for testing
        .executable(
            name: "heyfos-cli",
            targets: ["HeyFoSCLI"]
        ),
        // Web API server
        .executable(
            name: "heyfos-server",
            targets: ["HeyFoSAPI"]
        ),
        // Native Desktop app
        .executable(
            name: "HeyFoS",
            targets: ["HeyFoSApp"]
        )
    ],
    dependencies: [
        // Vapor web framework
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        // Swift Argument Parser for CLI
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        // Swift Log
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // C wrapper for LibRaw (C++ library)
        .target(
            name: "CLibRaw",
            dependencies: [],
            cxxSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"]),
            ],
            linkerSettings: [
                .linkedLibrary("raw"),
                .unsafeFlags(["-L/opt/homebrew/lib"])
            ]
        ),
        
        // Core processing engine
        .target(
            name: "HeyFoSCore",
            dependencies: [
                "CLibRaw",
                .product(name: "Logging", package: "swift-log")
            ],
            // Shaders.metal is embedded as a string in MetalShaderSource.swift for SPM
            // compatibility (SPM does not compile .metal files into a Metal library).
            exclude: ["Metal/Shaders.metal"]
        ),
        
        // CLI tool
        .executableTarget(
            name: "HeyFoSCLI",
            dependencies: [
                "HeyFoSCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        
        // Vapor web server
        .executableTarget(
            name: "HeyFoSAPI",
            dependencies: [
                "HeyFoSCore",
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        
        // Desktop app (SwiftUI, macOS 14+)
        .executableTarget(
            name: "HeyFoSApp",
            dependencies: [
                "HeyFoSCore",
            ]
        ),

        // Tests
        .testTarget(
            name: "HeyFoSCoreTests",
            dependencies: ["HeyFoSCore"]
        ),
    ]
)
