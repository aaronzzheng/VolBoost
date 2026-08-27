// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VolBoost",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "VolBoost",
            path: "Sources/VolBoost",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        )
    ]
)
