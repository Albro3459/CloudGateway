// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CloudGatewayKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CloudGatewayKit",
            targets: ["CloudGatewayKit"]
        ),
        .library(
            name: "CloudGatewayAppCore",
            targets: ["CloudGatewayAppCore"]
        ),
    ],
    targets: [
        .target(
            name: "CloudGatewayKit"
        ),
        .target(
            name: "CloudGatewayAppCore",
            dependencies: ["CloudGatewayKit"]
        ),
        .testTarget(
            name: "CloudGatewayKitTests",
            dependencies: ["CloudGatewayKit"]
        ),
        .testTarget(
            name: "CloudGatewayAppCoreTests",
            dependencies: ["CloudGatewayAppCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
