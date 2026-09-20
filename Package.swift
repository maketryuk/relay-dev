// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relay",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "relay-daemon", targets: ["relay-daemon"]),
        .executable(name: "Relay", targets: ["RelayApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        // The tree-sitter grammars and their highlight queries — the same ones
        // VS Code, Zed and Neovim use. Pinned exactly because the bundle is
        // binary and its layout is what `Scripts/build-app.sh` repairs.
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", exact: "0.1.20"),
        // The tree-sitter bindings, now maintained by the tree-sitter project
        // itself. They parse in UTF-16, which is what makes the highlighter
        // above short: a node's range is already the range `NSTextStorage`
        // counts in, with no byte arithmetic in between to get wrong.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", exact: "0.9.0"),
    ],
    targets: [
        .target(name: "RelayProtocol"),
        .target(name: "RelayDaemonCore", dependencies: ["RelayProtocol"]),
        .executableTarget(name: "relay-daemon", dependencies: ["RelayDaemonCore"]),
        .target(
            name: "RelayUI",
            dependencies: ["RelayProtocol"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "RelayAppKit",
            dependencies: [
                "RelayProtocol",
                "RelayUI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            ]
        ),
        .executableTarget(name: "RelayApp", dependencies: ["RelayAppKit"]),

        .testTarget(name: "RelayProtocolTests", dependencies: ["RelayProtocol"]),
        .testTarget(name: "RelayDaemonCoreTests", dependencies: ["RelayDaemonCore"]),
.testTarget(name: "RelayAppKitTests", dependencies: ["RelayAppKit", "RelayUI"]),
    ]
)
