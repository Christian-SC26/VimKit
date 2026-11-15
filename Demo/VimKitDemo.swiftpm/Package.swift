// swift-tools-version: 5.9

// iPad / iPhone demo for VimKit. Open this folder in Xcode (or Swift
// Playgrounds) and run it. With a hardware keyboard (or the Mac keyboard in
// the simulator: I/O › Keyboard › Connect Hardware Keyboard) Vim keys work
// as on the Mac; with the on-screen keyboard, letters typed in normal mode
// run as commands.

import AppleProductTypes
import PackageDescription

let package = Package(
    name: "VimKitDemo",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "VimKit Demo",
            targets: ["AppModule"],
            bundleIdentifier: "dev.vimkit.demo",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .pencil),
            accentColor: .presetColor(.green),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait, .landscapeRight, .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad])),
            ]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [.product(name: "VimKit", package: "VimKit")],
            path: "."
        ),
    ]
)
