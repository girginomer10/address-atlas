// swift-tools-version: 5.10

import PackageDescription

let package = Package(
  name: "AddressAtlasMac",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
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
      dependencies: ["AddressAtlasCore"],
      resources: [
        // Bundled OFL fonts and their licences, registered at runtime by
        // AtlasFonts. The iOS project ships the same folder as a resource.
        .copy("Fonts")
      ]
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
