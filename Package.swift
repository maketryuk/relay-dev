// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "relay-daemon", targets: ["relay-daemon"]),
        .executable(name: "Relay", targets: ["RelayApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
    ],
    targets: [
        .target(name: "RelayProtocol"),
        .target(name: "RelayDaemonCore", dependencies: ["RelayProtocol"]),
        .executableTarget(name: "relay-daemon", dependencies: ["RelayDaemonCore"]),
        .target(name: "RelayUI", dependencies: ["RelayProtocol"]),
        .target(
            name: "RelayAppKit",
            dependencies: [
                "RelayProtocol",
                "RelayUI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(name: "RelayApp", dependencies: ["RelayAppKit"]),

        .testTarget(name: "RelayProtocolTests", dependencies: ["RelayProtocol"]),
        .testTarget(name: "RelayDaemonCoreTests", dependencies: ["RelayDaemonCore"]),
        .testTarget(name: "RelayAppKitTests", dependencies: ["RelayAppKit", "RelayUI"]),
    ]
)
