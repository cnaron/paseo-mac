// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaseoMac",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "PaseoMac", targets: ["PaseoMacApp"]),
        .library(name: "PaseoCore", targets: ["PaseoCore"]),
        .library(name: "PaseoUI", targets: ["PaseoUI"]),
    ],
    dependencies: [
        // Vendored under .vendor/swift-sodium because Air's git proxy is unreachable
        // offline. Clone source: https://github.com/jedisct1/swift-sodium
        .package(path: ".vendor/swift-sodium")
    ],
    targets: [
        .target(
            name: "PaseoCore",
            dependencies: [
                .product(name: "Clibsodium", package: "swift-sodium")
            ],
            path: "Sources/PaseoCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PaseoUI",
            dependencies: ["PaseoCore"],
            path: "Sources/PaseoUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PaseoMacApp",
            dependencies: ["PaseoCore", "PaseoUI"],
            path: "Sources/PaseoMacApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
