// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Retroteca",
    defaultLocalization: "it",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RetrotecaCore", path: "Sources/RetrotecaCore"),
        .executableTarget(
            name: "Retroteca",
            dependencies: ["RetrotecaCore"],
            path: "Sources/Retroteca"
        ),
        .testTarget(
            name: "RetrotecaCoreTests",
            dependencies: ["RetrotecaCore"],
            path: "Tests/RetrotecaCoreTests"
        )
    ]
)
