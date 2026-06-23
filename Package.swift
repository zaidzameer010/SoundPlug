// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SoundPlug",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SoundPlug", targets: ["SoundPlug"])
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "SoundPlug",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SoundPlug/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "SoundPlugTests",
            dependencies: ["SoundPlug"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
