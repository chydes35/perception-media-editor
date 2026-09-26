// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "PerceptionEdit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "PerceptionEditor", targets: ["PerceptionEditor"])
    ],
    targets: [
        .executableTarget(
            name: "PerceptionEditor",
            linkerSettings: [
                .linkedFramework("AVKit")
            ]
        )
    ]
)
