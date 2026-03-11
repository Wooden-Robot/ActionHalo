// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "OpenFire",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OpenFire", targets: ["OpenFire"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "OpenFire",
            path: "Sources/OpenFire",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("JavaScriptCore")
            ]
        ),
        .testTarget(
            name: "OpenFireTests",
            dependencies: ["OpenFire"],
            path: "Tests/OpenFireTests"
        )
    ]
)
