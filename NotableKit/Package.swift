// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotableKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "NotableKit", targets: ["NotableKit"])
    ],
    targets: [
        .target(name: "NotableKit"),
        .testTarget(name: "NotableKitTests", dependencies: ["NotableKit"]),
    ]
)
