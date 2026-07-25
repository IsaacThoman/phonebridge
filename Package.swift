// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "phonebridge",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PhoneBridgeCore", targets: ["PhoneBridgeCore"]),
    .executable(name: "phonebridge", targets: ["phonebridge"]),
    .executable(name: "PhoneBridgeMacApp", targets: ["PhoneBridgeMacApp"]),
  ],
  dependencies: [
    .package(url: "https://github.com/stasel/WebRTC.git", from: "150.0.0")
  ],
  targets: [
    .target(
      name: "PhoneBridgeCore",
      dependencies: [
        .product(name: "WebRTC", package: "WebRTC")
      ],
      resources: [.process("Resources/Web")],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Contacts"),
        .linkedFramework("Network"),
        .linkedFramework("Security"),
      ]
    ),
    .executableTarget(
      name: "phonebridge",
      dependencies: ["PhoneBridgeCore"],
      exclude: ["Resources/Info.plist"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/phonebridge/Resources/Info.plist",
        ])
      ]
    ),
    .executableTarget(
      name: "PhoneBridgeMacApp",
      dependencies: ["PhoneBridgeCore"],
      exclude: ["Resources/Info.plist"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/PhoneBridgeMacApp/Resources/Info.plist",
        ]),
      ]
    ),
    .testTarget(
      name: "PhoneBridgeCoreTests",
      dependencies: ["PhoneBridgeCore"]
    ),
  ]
)
