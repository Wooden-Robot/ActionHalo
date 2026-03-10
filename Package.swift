// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "OpenFire",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "OpenFire",
            path: "Sources/OpenFire",
            resources: [
                .copy("Resources/Info.plist")
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("JavaScriptCore")
            ]
        )
    ]
)
