// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Gauge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(name: "Gauge",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Gauge",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                             .linkedFramework("ServiceManagement"),
                             .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ]
)
