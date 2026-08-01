// swift-tools-version: 5.9
import PackageDescription

// GitKittieKit — the shared Swift package for GitKittie's native apps
// (GitFolder, GitKanban, GitBud).
//
// Owns the git engine, history/rewrite primitives and app services, plus the
// GitKanban board model that mirrors @gitkittie/gitkanban-core.
// See project-assets/GitKittie/GitKanban/plan and the Tasks/GitKit board.
let package = Package(
    name: "GitKittieKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "GitKittieKit", targets: ["GitKittieKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        .target(name: "GitKittieKit", dependencies: ["Yams"]),
        .testTarget(name: "GitKittieKitTests", dependencies: ["GitKittieKit"])
    ]
)
