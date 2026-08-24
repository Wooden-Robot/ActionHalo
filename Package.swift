// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "ActionHalo",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "ActionHalo", targets: ["ActionHalo"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        )
    ],
    targets: [
        .executableTarget(
            name: "ActionHalo",
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
            name: "ActionHaloTests",
            dependencies: ["ActionHalo"],
            path: "Tests/ActionHaloTests"
        )
    ]
)
