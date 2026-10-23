// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CloudGatewayMacCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CloudGatewayMacCore", targets: ["CloudGatewayMacCore"]),
        .library(name: "CloudGatewayMacIPC", targets: ["CloudGatewayMacIPC"]),
        .library(name: "CloudGatewayMacControllerIPC", targets: ["CloudGatewayMacControllerIPC"]),
        .library(name: "CloudGatewayMacCLI", targets: ["CloudGatewayMacCLI"]),
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
        .target(name: "CloudGatewayMacCLI", dependencies: [
            "CloudGatewayMacCore",
            "CloudGatewayMacControllerIPC",
            .product(name: "CloudGatewayKit", package: "CloudGatewayKit"),
        ]),
        .testTarget(name: "CloudGatewayMacIPCTests", dependencies: ["CloudGatewayMacIPC"]),
        .testTarget(name: "CloudGatewayMacCoreTests", dependencies: ["CloudGatewayMacCore", "CloudGatewayMacControllerIPC", "CloudGatewayMacCLI"]),
        .testTarget(name: "CloudGatewayMacControllerIPCTests", dependencies: ["CloudGatewayMacControllerIPC"]),
        .testTarget(name: "CloudGatewayMacCLITests", dependencies: [
            "CloudGatewayMacCLI",
            "CloudGatewayMacCore",
            "CloudGatewayMacControllerIPC",
            .product(name: "CloudGatewayKit", package: "CloudGatewayKit"),
            .product(name: "CloudGatewayAppCore", package: "CloudGatewayKit"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
