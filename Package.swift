// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaseoMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PaseoMac", targets: ["PaseoMacApp"])
    ],
    dependencies: [
        // Vendored under .vendor/swift-sodium because Air's git proxy is unreachable
        // offline. Clone source: https://github.com/jedisct1/swift-sodium
        .package(path: ".vendor/swift-sodium")
    ],
    targets: [
        // Phase-0: all three layers compiled in one module so the existing
        // internal access level is preserved across the PaseoCore / PaseoUI /
        // PaseoMacApp directories. The directory split documents the intended
        // future module boundaries; the true three-target split (with public
        // APIs) is Phase 1 when iOS is added.
        .executableTarget(
            name: "PaseoMacApp",
            dependencies: [
                .product(name: "Clibsodium", package: "swift-sodium")
            ],
            path: "Sources",
            sources: [
                "PaseoCore",
                "PaseoUI",
                "PaseoMacApp",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
