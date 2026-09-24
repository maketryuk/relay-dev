// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relay",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "relay-daemon", targets: ["relay-daemon"]),
        .executable(name: "Relay", targets: ["RelayApp"]),
        .executable(name: "relay-browser-helper", targets: ["relay-browser-helper"]),
        .executable(name: "relay-hook", targets: ["relay-hook"]),
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
        // GitHub's own Markdown parser, with its tables, task lists and
        // strikethrough, so a README reads in the preview the way it will on
        // GitHub. C with a module map and no dependencies of its own.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
    ],
    targets: [
        .target(name: "RelayProtocol"),
        .target(name: "RelayDaemonCore", dependencies: ["RelayProtocol"]),
        .executableTarget(name: "relay-daemon", dependencies: ["RelayDaemonCore"]),
        // What an agent's hook runs inside a Relay terminal. Its own executable
        // because an agent waits for its hooks: it starts in milliseconds and
        // links nothing but the protocol.
        .executableTarget(name: "relay-hook", dependencies: ["RelayProtocol"]),
        .target(
            name: "RelayUI",
            dependencies: ["RelayProtocol"],
            resources: [.process("Resources")]
        ),
        // The browser pane's Chromium, reached through CEF's C API. Only the
        // headers live here: the framework is loaded at run time from the app
        // bundle, which `Scripts/build-app.sh` fills, so a build or a test run
        // needs nothing downloaded. The API version pins the layout of every
        // structure in those headers; `Chromium.c` refuses a framework whose
        // layout differs.
        .target(
            name: "CChromium",
            exclude: ["cef/LICENSE.txt"],
            cSettings: [
                .headerSearchPath("cef"),
                .define("CEF_API_VERSION", to: "15400"),
            ],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // The executable Chromium runs its renderer, GPU and utility processes
        // in, copied into the bundle once per kind of process.
        .executableTarget(name: "relay-browser-helper", dependencies: ["CChromium"]),
        .target(
            name: "RelayAppKit",
            dependencies: [
                "CChromium",
                "RelayProtocol",
                "RelayUI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .executableTarget(name: "RelayApp", dependencies: ["RelayAppKit"]),

        .testTarget(name: "RelayProtocolTests", dependencies: ["RelayProtocol"]),
        .testTarget(name: "RelayDaemonCoreTests", dependencies: ["RelayDaemonCore"]),
.testTarget(name: "RelayAppKitTests", dependencies: ["RelayAppKit", "RelayUI"]),
    ]
)
