// swift-tools-version: 5.9
import PackageDescription

// TrailheadCore —— 纯逻辑层（Models / Stores / Services），无 UI 依赖。
// App 依赖它；测试 hostless，`swift test` 在 macOS 上秒级跑、CI 稳定。
let package = Package(
    name: "TrailheadCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TrailheadCore", targets: ["TrailheadCore"]),
    ],
    targets: [
        .target(name: "TrailheadCore"),
        .testTarget(name: "TrailheadCoreTests", dependencies: ["TrailheadCore"]),
    ]
)
