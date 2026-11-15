// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VimKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Editor-agnostic Vim engine (JavaScriptCore). Works on macOS and iOS.
        .library(name: "VimCore", targets: ["VimCore"]),
        // AppKit / UIKit text views and a SwiftUI editor built on VimCore.
        .library(name: "VimKit", targets: ["VimKit"]),
        .executable(name: "VimKitDemo", targets: ["VimKitDemo"]),
        // Performance stand: `swift run -c release VimKitBench`.
        .executable(name: "VimKitBench", targets: ["VimKitBench"]),
    ],
    targets: [
        .target(
            name: "VimCore",
            exclude: ["Resources/VENDORED.txt"],
            resources: [
                .copy("Resources/vim.js"),
                .copy("Resources/vimkit-adapter.js"),
                .copy("Resources/codemirror-vim-LICENSE.txt"),
            ]
        ),
        .target(name: "VimKit", dependencies: ["VimCore"]),
        .executableTarget(name: "VimKitDemo", dependencies: ["VimKit"]),
        .executableTarget(name: "VimKitBench", dependencies: ["VimKit"]),
        .testTarget(
            name: "VimCoreTests",
            dependencies: ["VimCore"],
            resources: [
                .copy("Resources/vim_test.js"),
                .copy("Resources/upstream-harness.js"),
                .copy("Resources/upstream-known-failures.txt"),
            ]
        ),
        .testTarget(name: "VimKitTests", dependencies: ["VimKit"]),
    ]
)
