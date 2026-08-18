// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ACActionCable",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ACActionCable",
            targets: ["ACActionCable"]),
    ],
    targets: [
        .target(
            name: "ACActionCable"),
        .testTarget(
            name: "ACActionCableTests",
            dependencies: ["ACActionCable"]),
    ]
)
