// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VimKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Editor-agnostic Vim engine (JavaScriptCore). Works on macOS and iOS.
        .library(name: "VimCore", targets: ["VimCore"]),
        // AppKit text view and SwiftUI editor built on VimCore (macOS).
        .library(name: "VimKit", targets: ["VimKit"]),
        .executable(name: "VimKitDemo", targets: ["VimKitDemo"]),
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
