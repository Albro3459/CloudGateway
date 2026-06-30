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
    ],
    targets: [
        .target(
            name: "CloudGatewayKit"
        ),
        .testTarget(
            name: "CloudGatewayKitTests",
            dependencies: ["CloudGatewayKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
