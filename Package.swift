// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "agymux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "agymux", targets: ["agymux"]),
        .library(name: "AgymuxCore", targets: ["AgymuxCore"])
    ],
    targets: [
        .target(
            name: "AgymuxCore",
            path: "Sources/AgymuxCore"
        ),
        .executableTarget(
            name: "agymux",
            dependencies: ["AgymuxCore"],
            path: "Sources/agymux"
        ),
        .testTarget(
            name: "AgymuxTests",
            dependencies: ["AgymuxCore"],
            path: "Tests/AgymuxTests"
        )
    ]
)
