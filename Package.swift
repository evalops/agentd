// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agentd",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentd", targets: ["agentd"])
    ],
    targets: [
        .executableTarget(
            name: "agentd",
            path: "Sources/agentd",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "support/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "agentdTests",
            dependencies: ["agentd"],
            path: "Tests/agentdTests"
        )
    ]
)
