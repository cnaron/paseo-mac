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
    targets: [
        .executableTarget(
            name: "PaseoMac",
            path: "Sources/PaseoMac",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
