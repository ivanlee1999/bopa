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
    dependencies: [
        // Test-only: snapshot assertions for rendered output. Consumers of the
        // library never build this.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0")
    ],
    targets: [
        .target(name: "NotableKit"),
        .testTarget(
            name: "NotableKitTests",
            dependencies: [
                "NotableKit",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
    ]
)
