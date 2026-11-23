// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SSDMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SSDMonitor",
            path: "Sources/SSDMonitor",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
