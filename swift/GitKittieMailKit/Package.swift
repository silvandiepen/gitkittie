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
// - MailMIME         RFC 5322/MIME parsing and generation, Foundation only (GKM-002, MAIL-017)
// - MailCompose      drafts, reply/forward headers, Markdown to safe HTML, the outgoing bytes (GKM-013)
// - MailHTML         hostile-HTML sanitizer and HTML-to-text, Foundation only (GKM-012)
// - MailReader       what the reader shows: thread, sender and link checks, inline parts (GKM-012)
// - MailReaderWeb    the locked-down WKWebView the reader renders HTML in (GKM-012)
// - MailExtraction   attachment text for search, PDF and plain text; run it isolated (GKM-016)
//
// The provider adapters (IMAP, SMTP) live in swift/GitKittieMailProviders: they need
// swift-nio-imap, which needs Swift 6.2 and macOS 15 / iOS 18 (MAIL-017).
let package = Package(
    name: "GitKittieMailKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MailCore", targets: ["MailCore"]),
        .library(name: "MailStore", targets: ["MailStore"]),
        .library(name: "MailClassifier", targets: ["MailClassifier"]),
        .library(name: "MailMIME", targets: ["MailMIME"]),
        .library(name: "MailCompose", targets: ["MailCompose"]),
        .library(name: "MailHTML", targets: ["MailHTML"]),
        .library(name: "MailReader", targets: ["MailReader"]),
        .library(name: "MailReaderWeb", targets: ["MailReaderWeb"]),
        .library(name: "MailExtraction", targets: ["MailExtraction"]),
    ],
    targets: [
        .target(name: "MailCore"),
        .target(name: "MailStore", dependencies: ["MailCore", "MailMIME", "MailHTML"]),
        .target(name: "MailClassifier", dependencies: ["MailCore"]),
        .target(name: "MailTestSupport", dependencies: ["MailCore"], resources: [.copy("Fixtures")]),
        .target(name: "MailMIME", dependencies: ["MailCore"]),
        .target(name: "MailCompose", dependencies: ["MailCore", "MailMIME", "MailStore"]),
        .target(name: "MailHTML"),
        .target(name: "MailReader", dependencies: ["MailCore", "MailMIME", "MailHTML", "MailStore", "MailClassifier"]),
        .target(name: "MailReaderWeb", dependencies: ["MailReader", "MailHTML"]),
        .target(name: "MailExtraction"),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore", "MailTestSupport"]),
        .testTarget(name: "MailClassifierTests", dependencies: ["MailClassifier", "MailTestSupport"]),
        .testTarget(name: "MailMIMETests", dependencies: ["MailMIME"]),
        .testTarget(name: "MailComposeTests", dependencies: ["MailCompose", "MailMIME", "MailStore", "MailTestSupport"]),
        .testTarget(name: "MailHTMLTests", dependencies: ["MailHTML", "MailTestSupport"]),
        .testTarget(name: "MailReaderTests", dependencies: ["MailReader", "MailReaderWeb", "MailStore", "MailTestSupport"]),
        .testTarget(name: "MailExtractionTests", dependencies: ["MailExtraction"]),
    ]
)
