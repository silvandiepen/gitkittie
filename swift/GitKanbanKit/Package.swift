// swift-tools-version: 5.9
import PackageDescription

// GitKanbanKit — the shared GitKanban app layer (view model + provider transport),
// consumed by both GitKanban iOS and GitKanban macOS so there is one tested copy.
//
// It sits above GitKittieKit (board schema/parse, provider-agnostic) and git-pont (the
// hosted-provider REST transport). It contains no SwiftUI/UIKit/AppKit — only the
// Observable `AppModel`, the board file sources, and the persisted repo/board model.
let package = Package(
    name: "GitKanbanKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GitKanbanKit", targets: ["GitKanbanKit"])
    ],
    dependencies: [
        .package(path: "../GitKittieKit"),
        .package(url: "https://github.com/silvandiepen/git-pont.git", branch: "codex/initial-git-pont-monorepo")
    ],
    targets: [
        .target(
            name: "GitKanbanKit",
            dependencies: [
                "GitKittieKit",
                .product(name: "GitPontCore", package: "git-pont"),
                .product(name: "GitPontGitHub", package: "git-pont"),
                .product(name: "GitPontGitLab", package: "git-pont")
            ]
        ),
        .testTarget(
            name: "GitKanbanKitTests",
            dependencies: ["GitKanbanKit", "GitKittieKit"]
        )
    ]
)
