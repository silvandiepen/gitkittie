// swift-tools-version: 5.9
import PackageDescription

// GitKittieMailKit — the UI-independent core of GitKittie Mail (apps/gitmail-macos, later
// -ios). Plan and decisions: apps/gitmail-macos/docs (Plan.md, Decisions.md). Each target is
// owned by a GKM card on the GitKittie board:
//
// - MailCore         shared models: accounts, addresses, message identity (GKM-005)
// - MailStore        EML + Markdown files, blobs, the rebuildable index (GKM-005)
// - MailClassifier   purpose, risk and urgency with reasons (GKM-007, GKM-017)
// - MailTestSupport  the synthetic fixture corpus (GKM-003); tests only, never shipped
//
// Protocol targets (IMAP, SMTP, MIME) are added by GKM-002 once the libraries are chosen.
let package = Package(
    name: "GitKittieMailKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MailCore", targets: ["MailCore"]),
        .library(name: "MailStore", targets: ["MailStore"]),
        .library(name: "MailClassifier", targets: ["MailClassifier"]),
    ],
    targets: [
        .target(name: "MailCore"),
        .target(name: "MailStore", dependencies: ["MailCore"]),
        .target(name: "MailClassifier", dependencies: ["MailCore"]),
        .target(name: "MailTestSupport", dependencies: ["MailCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore", "MailTestSupport"]),
        .testTarget(name: "MailClassifierTests", dependencies: ["MailClassifier", "MailTestSupport"]),
    ]
)
