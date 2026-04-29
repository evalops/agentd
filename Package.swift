// swift-tools-version: 6.0
// SPDX-License-Identifier: BUSL-1.1
import PackageDescription

let package = Package(
  name: "agentd",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "agentd", targets: ["agentd"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
  ],
  targets: [
    .executableTarget(
      name: "agentd",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ],
      path: "Sources/agentd",
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "support/Info.plist",
          "-Xlinker", "-rpath",
          "-Xlinker", "@executable_path/../Frameworks",
        ])
      ]
    ),
    .testTarget(
      name: "agentdTests",
      dependencies: ["agentd"],
      path: "Tests/agentdTests"
    ),
  ]
)
