// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CloudGatewayFirebaseAdapter",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CloudGatewayFirebaseAuthAdapter",
            targets: ["CloudGatewayFirebaseAuthAdapter"]
        ),
    ],
    dependencies: [
        .package(path: "../CloudGatewayKit"),
        .package(
            url: "https://github.com/firebase/firebase-ios-sdk.git",
            exact: "11.15.0"
        ),
    ],
    targets: [
        .target(
            name: "CloudGatewayFirebaseAuthAdapter",
            dependencies: [
                .product(name: "CloudGatewayAppCore", package: "CloudGatewayKit"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
            ]
        ),
        .testTarget(
            name: "CloudGatewayFirebaseAuthAdapterTests",
            dependencies: ["CloudGatewayFirebaseAuthAdapter"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
