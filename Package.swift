// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Millr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Millr",
            path: "Sources/Millr",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("CoreServices"),
            ]
        )
    ]
)
