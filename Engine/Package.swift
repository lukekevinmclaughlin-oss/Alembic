// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AlembicEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AlembicEngine", targets: ["AlembicEngine"])
    ],
    targets: [
        .target(
            name: "AlembicEngine",
            resources: [.copy("Resources/cl100k_base.tiktoken")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AlembicEngineTests",
            dependencies: ["AlembicEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
