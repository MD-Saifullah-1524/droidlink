// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DroidLink",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.25.3"
        )
    ],
    targets: [
        .executableTarget(
            name: "DroidLink",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Sources",
            exclude: [
                "DroidLink/DroidLink.entitlements",
                "DroidLink/Info.plist",
                "DroidLinkFileProvider/DroidLinkFileProvider.entitlements",
                "DroidLinkFileProvider/Info.plist"
            ]
        ),
        .testTarget(
            name: "DroidLinkTests",
            dependencies: [
                "DroidLink"
            ],
            path: "Tests/DroidLinkTests"
        )
    ]
)