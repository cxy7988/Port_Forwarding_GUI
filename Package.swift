// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "PortForwardStudio",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PortForwardStudio", targets: ["PortForwardStudio"])
    ],
    targets: [
        .executableTarget(name: "PortForwardStudio"),
        .testTarget(
            name: "PortForwardStudioTests",
            dependencies: ["PortForwardStudio"]
        )
    ],
    swiftLanguageModes: [.v5]
)
