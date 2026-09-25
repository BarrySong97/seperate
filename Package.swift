// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Workbench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
        .binaryTarget(name: "WorkbenchCore", path: "Vendor/WorkbenchCore.xcframework"),
        .executableTarget(
            name: "Workbench",
            dependencies: ["GhosttyKit", "WorkbenchCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Workbench",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        // Called by agent hooks (Claude hooks, Codex notify); forwards the event to the running app.
        .executableTarget(
            name: "SeperateHook",
            path: "Sources/SeperateHook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // "安装 Seperate.app": the double-click installer inside the DMG.
        .executableTarget(
            name: "SeperateInstaller",
            path: "Sources/SeperateInstaller",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WorkbenchTests",
            dependencies: ["Workbench"],
            path: "Tests/WorkbenchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
