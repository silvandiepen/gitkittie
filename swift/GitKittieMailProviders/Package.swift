// swift-tools-version: 6.2
import PackageDescription

// GitKittieMailProviders — how GitKittie Mail talks to mail providers (GKM-002, MAIL-017).
// The app and the sync code use MailProvider's protocol-agnostic interfaces; only the adapters
// know a wire protocol. Models and MIME come from swift/GitKittieMailKit.
//
// - MailProvider   sessions, folders, remote ids, flags, send outcomes, reconnects, redaction
// - MailNet        transport shared by the adapters: TLS (swift-nio-ssl), timeouts
// - MailIMAP       IMAP adapter on Apple's swift-nio-imap codec
// - MailSMTP       SMTP submission, our own client on SwiftNIO (implicit TLS and STARTTLS)
// - MailOutbox     the durable outbox: journal, at-most-once sending, Sent reconciliation (GKM-014)
// - MailSpikeKit   the GKM-004 end-to-end scenario; `gkmail-spike` runs it against an account
//
// A separate package because swift-nio-imap 0.5 needs Swift 6.2 and macOS 15 / iOS 18, while
// the app and GitKittieMailKit still build for macOS 14 with Xcode 16. The app adopts this
// package (and the higher floor) when it starts syncing (GKM-010/011).
let protocolSettings: [SwiftSetting] = [
    // Nonisolated async code runs on the caller's executor (SE-0461), which is what lets one
    // task drive a non-Sendable connection without crossing isolation.
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "GitKittieMailProviders",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MailProvider", targets: ["MailProvider"]),
        .library(name: "MailIMAP", targets: ["MailIMAP"]),
        .library(name: "MailSMTP", targets: ["MailSMTP"]),
        .library(name: "MailOutbox", targets: ["MailOutbox"]),
        .executable(name: "gkmail-spike", targets: ["MailSpike"]),
    ],
    dependencies: [
        .package(path: "../GitKittieMailKit"),
        // 0.x: a minor release may break the API, so stay on 0.5.x until we move deliberately.
        .package(url: "https://github.com/apple/swift-nio-imap.git", .upToNextMinor(from: "0.5.0")),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
    ],
    targets: [
        .target(name: "MailProvider", swiftSettings: protocolSettings),
        .target(
            name: "MailNet",
            dependencies: [
                "MailProvider",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: protocolSettings
        ),
        .target(
            name: "MailIMAP",
            dependencies: [
                "MailProvider", "MailNet",
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: protocolSettings
        ),
        .target(
            name: "MailSMTP",
            dependencies: [
                "MailProvider", "MailNet",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: protocolSettings
        ),
        .target(
            name: "MailOutbox",
            dependencies: [
                "MailProvider", "MailSMTP", "MailIMAP",
                .product(name: "MailCore", package: "GitKittieMailKit"),
                .product(name: "MailStore", package: "GitKittieMailKit"),
                .product(name: "MailCompose", package: "GitKittieMailKit"),
            ],
            swiftSettings: protocolSettings
        ),
        .target(
            name: "MailSpikeKit",
            dependencies: [
                "MailProvider", "MailIMAP", "MailSMTP",
                .product(name: "MailCore", package: "GitKittieMailKit"),
                .product(name: "MailMIME", package: "GitKittieMailKit"),
            ],
            swiftSettings: protocolSettings
        ),
        .executableTarget(
            name: "MailSpike",
            dependencies: ["MailSpikeKit", "MailProvider"],
            swiftSettings: protocolSettings
        ),

        .testTarget(
            name: "MailProviderTests",
            dependencies: ["MailProvider", .product(name: "NIOConcurrencyHelpers", package: "swift-nio")],
            swiftSettings: protocolSettings
        ),
        .testTarget(
            name: "MailIMAPTests",
            dependencies: ["MailIMAP", "MailProvider", .product(name: "NIOIMAP", package: "swift-nio-imap")],
            swiftSettings: protocolSettings
        ),
        .testTarget(
            name: "MailOutboxTests",
            dependencies: [
                "MailOutbox", "MailProvider",
                .product(name: "MailCore", package: "GitKittieMailKit"),
                .product(name: "MailCompose", package: "GitKittieMailKit"),
                .product(name: "MailMIME", package: "GitKittieMailKit"),
            ],
            swiftSettings: protocolSettings
        ),
        .testTarget(
            name: "MailSMTPTests",
            dependencies: ["MailSMTP", "MailProvider", .product(name: "NIOEmbedded", package: "swift-nio")],
            swiftSettings: protocolSettings
        ),
        // Talk to a real local mail server (scripts/test-mail-server.sh); skipped when it is down.
        .testTarget(
            name: "MailIntegrationTests",
            dependencies: [
                "MailProvider", "MailIMAP", "MailSMTP", "MailSpikeKit", "MailOutbox",
                .product(name: "MailCore", package: "GitKittieMailKit"),
                .product(name: "MailMIME", package: "GitKittieMailKit"),
                .product(name: "MailCompose", package: "GitKittieMailKit"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: protocolSettings
        ),
    ]
)
