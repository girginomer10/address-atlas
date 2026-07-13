// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "AddressAtlasMac",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AddressAtlasCore", targets: ["AddressAtlasCore"]),
    .executable(name: "AddressAtlasMac", targets: ["AddressAtlasMac"])
  ],
  targets: [
    .target(
      name: "AddressAtlasCore",
      linkerSettings: [
        .linkedFramework("Security"),
        .linkedLibrary("sqlite3")
      ]
    ),
    .executableTarget(
      name: "AddressAtlasMac",
      dependencies: ["AddressAtlasCore"]
    ),
    .testTarget(
      name: "AddressAtlasCoreTests",
      dependencies: ["AddressAtlasCore"]
    ),
    .testTarget(
      name: "AddressAtlasMacTests",
      dependencies: ["AddressAtlasMac", "AddressAtlasCore"]
    )
  ]
)
