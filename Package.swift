// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaseoMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PaseoMac", targets: ["PaseoMac"]),
        .executable(name: "PaseoUsageWidget", targets: ["PaseoUsageWidget"])
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
        ),
        // Standalone menu-bar widget showing Claude Code 5h/7d quota.
        // Independent of the main app — talks straight to the VPS usage
        // proxy and stays visible regardless of which client (PaseoMac
        // native or upstream Electron) the user is using.
        .executableTarget(
            name: "PaseoUsageWidget",
            path: "Sources/PaseoUsageWidget",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
