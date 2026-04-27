// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaseoMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PaseoMac", targets: ["PaseoMac"])
    ],
    dependencies: [
        // Vendored under .vendor/swift-sodium because Air's git proxy is unreachable
        // offline. Clone source: https://github.com/jedisct1/swift-sodium
        .package(path: ".vendor/swift-sodium")
    ],
    targets: [
        .executableTarget(
            name: "PaseoMac",
            dependencies: [
                .product(name: "Clibsodium", package: "swift-sodium")
            ],
            path: "Sources/PaseoMac",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
