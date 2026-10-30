// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HookScope",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HookScope", targets: ["HookScope"]),
        .executable(name: "hook-recorder", targets: ["HookRecorder"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "HookCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "HookRecorder", dependencies: ["HookCore"]),
        .executableTarget(name: "HookScope", dependencies: ["HookCore"]),
        .testTarget(name: "HookCoreTests", dependencies: ["HookCore"])
    ],
    swiftLanguageModes: [.v5]
)
