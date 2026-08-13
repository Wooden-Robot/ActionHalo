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
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        )
    ],
    targets: [
        .executableTarget(
            name: "OpenFire",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/App",
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
