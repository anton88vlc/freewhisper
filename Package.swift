// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FreeWhisper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "freewhisper", targets: ["FreeWhisper"])
    ],
    targets: [
        .executableTarget(
            name: "FreeWhisper",
            path: "Sources"
        )
    ]
)
