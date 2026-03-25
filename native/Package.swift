// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XrayNative",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "XrayNativeCore",
            targets: ["XrayNativeCore"]
        ),
        .library(
            name: "XrayNativeDesktopRuntime",
            targets: ["XrayNativeDesktopRuntime"]
        ),
        .executable(
            name: "XrayNativeMacApp",
            targets: ["XrayNativeMacApp"]
        ),
    ],
    targets: [
        .target(
            name: "XrayNativeCore"
        ),
        .target(
            name: "XrayNativeDesktopRuntime",
            dependencies: ["XrayNativeCore"]
        ),
        .executableTarget(
            name: "XrayNativeMacApp",
            dependencies: [
                "XrayNativeCore",
                "XrayNativeDesktopRuntime",
            ]
        ),
        .testTarget(
            name: "XrayNativeCoreTests",
            dependencies: ["XrayNativeCore"]
        ),
    ]
)
