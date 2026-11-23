// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "road-secrets",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "road-secrets", targets: ["road-secrets"]),
    ],
    targets: [
        .target(name: "RoadSecretsCore"),
        .executableTarget(name: "road-secrets", dependencies: ["RoadSecretsCore"]),
        .testTarget(name: "RoadSecretsCoreTests", dependencies: ["RoadSecretsCore"]),
    ],
    swiftLanguageModes: [.v5]
)
