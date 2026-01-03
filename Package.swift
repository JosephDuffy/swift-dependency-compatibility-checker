// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-dependency-compatibility-checker",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "swift-dependency-compatibility-checker", targets: ["swift-dependency-compatibility-checker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.2.1"),
        .package(url: "https://github.com/SwiftPackageIndex/SemanticVersion.git", from: "0.5.1"),
    ],
    targets: [
        .executableTarget(
            name: "swift-dependency-compatibility-checker",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                "SemanticVersion",
            ]
        ),
    ]
)
