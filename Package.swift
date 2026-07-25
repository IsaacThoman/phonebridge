// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "phonebridge",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PhoneBridgeCore", targets: ["PhoneBridgeCore"]),
    .executable(name: "phonebridge", targets: ["phonebridge"]),
  ],
  targets: [
    .target(
      name: "PhoneBridgeCore",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Contacts"),
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
    .testTarget(
      name: "PhoneBridgeCoreTests",
      dependencies: ["PhoneBridgeCore"]
    ),
  ]
)
