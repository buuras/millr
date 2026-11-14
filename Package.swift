// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OCCommander",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OCCommander",
            path: "Sources/OCCommander",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("CoreServices"),
            ]
        )
    ]
)
