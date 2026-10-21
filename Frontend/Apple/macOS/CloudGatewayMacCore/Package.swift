// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CloudGatewayMacCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CloudGatewayMacCore", targets: ["CloudGatewayMacCore"]),
        .library(name: "CloudGatewayMacIPC", targets: ["CloudGatewayMacIPC"]),
        .library(name: "CloudGatewayMacControllerIPC", targets: ["CloudGatewayMacControllerIPC"]),
    ],
    dependencies: [.package(path: "../../CloudGatewayKit")],
    targets: [
        .target(name: "CloudGatewayMacIPC", dependencies: [
            .product(name: "CloudGatewayKit", package: "CloudGatewayKit"),
        ]),
        .target(name: "CloudGatewayMacCore", dependencies: [
            "CloudGatewayMacIPC",
            .product(name: "CloudGatewayKit", package: "CloudGatewayKit"),
            .product(name: "CloudGatewayAppCore", package: "CloudGatewayKit"),
        ]),
        .target(name: "CloudGatewayMacControllerIPC", dependencies: [
            "CloudGatewayMacCore",
            "CloudGatewayMacIPC",
            .product(name: "CloudGatewayKit", package: "CloudGatewayKit"),
        ]),
        .testTarget(name: "CloudGatewayMacIPCTests", dependencies: ["CloudGatewayMacIPC"]),
        .testTarget(name: "CloudGatewayMacCoreTests", dependencies: ["CloudGatewayMacCore"]),
        .testTarget(name: "CloudGatewayMacControllerIPCTests", dependencies: ["CloudGatewayMacControllerIPC"]),
    ],
    swiftLanguageModes: [.v6]
)
