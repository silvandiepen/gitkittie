// swift-tools-version: 5.9
import PackageDescription

// GitKanbanKit — the shared GitKanban app layer (view model + provider transport),
// consumed by both GitKanban iOS and GitKanban macOS so there is one tested copy.
//
// It sits above GitKittieKit (board schema/parse, provider-agnostic) and git-pont (the
// hosted-provider REST transport). It contains no SwiftUI/UIKit/AppKit — only the
// Observable `AppModel`, the board file sources, and the persisted repo/board model.
//
// `TasksAgentTools` is the list of tools the app's agent server offers, in a target without
// dependencies so the `tasks` command-line tool (`TasksCLIKit` + the `tasks` executable)
// shares it with the server instead of keeping a copy, together with the CLI's command table and
// the agent guide (`tasks guide`, `get_agent_guide`).
let package = Package(
    name: "GitKanbanKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GitKanbanKit", targets: ["GitKanbanKit"]),
        .library(name: "TasksAgentTools", targets: ["TasksAgentTools"]),
        .library(name: "TasksCLIKit", targets: ["TasksCLIKit"]),
        .executable(name: "tasks", targets: ["TasksCLI"])
    ],
    dependencies: [
        .package(path: "../GitKittieKit"),
        .package(url: "https://github.com/silvandiepen/git-pont.git", branch: "master")
    ],
    targets: [
        // The agent guide's prose is compiled into the binary (`PackageResources.AgentGuide_md`):
        // the `tasks` tool ships alone in Contents/Helpers, with no resource bundle beside it.
        .target(name: "TasksAgentTools", resources: [.embedInCode("AgentGuide.md")]),
        .target(name: "TasksCLIKit", dependencies: ["TasksAgentTools"]),
        .executableTarget(name: "TasksCLI", dependencies: ["TasksCLIKit"]),
        .target(
            name: "GitKanbanKit",
            dependencies: [
                "GitKittieKit",
                "TasksAgentTools",
                .product(name: "GitPontCore", package: "git-pont"),
                .product(name: "GitPontGitHub", package: "git-pont"),
                .product(name: "GitPontGitLab", package: "git-pont")
            ]
        ),
        .testTarget(
            name: "GitKanbanKitTests",
            dependencies: ["GitKanbanKit", "GitKittieKit", "TasksAgentTools", "TasksCLIKit"]
        )
    ]
)
