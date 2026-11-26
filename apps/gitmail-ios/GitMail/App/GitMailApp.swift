import SwiftUI

@main
struct GitMailApp: App {
    @State private var session: MobileSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let session = Launch.session()
        _session = State(initialValue: session)
        // Before launch finishes, or iOS drops the background tasks (MAIL-053).
        if !Launch.isUITest { MailBackgroundTasks.register(session) }
        // Before launch finishes too, so the notification that launched the app opens its
        // message (GKM-037).
        session.model.respondToNotifications()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(session.model)
                // The text-safe accent: buttons and links sit on raised dark rows too (GKM-061).
                .tint(Theme.accentText)
                // The GitKittie apps are navy: dark, like Tasks.
                .preferredColorScheme(.dark)
                // `gitkittie-mail://message/…` (GKM-033): before the store is open the model
                // keeps the link until it is.
                .onOpenURL { url in Task { await session.model.openLink(url) } }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await session.becameActive() }
            case .background:
                if !Launch.isUITest { session.backgroundNotice = MailBackgroundTasks.schedule() }
                Task { await session.enteredBackground(ApplicationBackgroundTasks()) }
            default:
                break
            }
        }
    }
}

/// How the app starts: the real folders, or, for UI tests, a fresh folder and a test Keychain
/// service, so a test never touches the person's mail (`-uiTestFreshStore`), and the local test
/// server's CA trusted for its accounts (Debug builds only; `UITestLaunch`).
enum Launch {
    static var isUITest: Bool { ProcessInfo.processInfo.arguments.contains("-uiTestFreshStore") }

    @MainActor
    static func session() -> MobileSession {
        guard isUITest else { return .live() }
        return UITestLaunch.session()
    }
}
