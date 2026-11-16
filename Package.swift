// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quote0UI",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Quote0UI", targets: ["Quote0UI"])],
    targets: [
        .executableTarget(name: "Quote0UI", resources: [.copy("Resources/BundledScripts")]),
        .testTarget(name: "Quote0UITests", dependencies: ["Quote0UI"], exclude: ["Fixtures"])
    ]
)
