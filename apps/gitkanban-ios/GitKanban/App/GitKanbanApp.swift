import SwiftUI
import GitKanbanKit

@main
struct GitKanbanApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(CaptureHooks.colorScheme)
                .task {
                    // Test hook: launch with GITKANBAN_DEMO=1 to open the offline demo.
                    if CaptureHooks.isDemo {
                        await model.loadDemo()
                        CaptureHooks.applyRoute(to: model)
                    } else {
                        await model.restore()
                    }
                }
        }
    }
}

/// Launch hooks that let `@sil/app-release` drive the app for App Store screenshots and
/// promo videos (see `release/ios.json`). A capture has to be reproducible: same data,
/// same appearance, same screen. The simulator device fixes the pixel size, so unlike the
/// macOS app there is no window to resize here — only the demo data, colour scheme, and
/// starting screen are pinned. Every hook is a no-op when its variable is unset, so a
/// normal launch behaves exactly as before.
enum CaptureHooks {
    private static let environment = ProcessInfo.processInfo.environment

    /// `GITKANBAN_DEMO=1` — load the offline demo board instead of restoring a session.
    static var isDemo: Bool { environment["GITKANBAN_DEMO"] == "1" }

    /// `GITKANBAN_APPEARANCE=light|dark` — pin the appearance so both variants are
    /// reproducible rather than following the simulator's current setting.
    static var colorScheme: ColorScheme? {
        switch environment["GITKANBAN_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// `GITKANBAN_DEMO_ROUTE=board|card|search` — the screen to open once the demo board
    /// has loaded. Defaults to the board itself.
    @MainActor
    static func applyRoute(to model: AppModel) {
        switch environment["GITKANBAN_DEMO_ROUTE"] {
        case "card":
            model.selectedCard = model.board?.columns.first(where: { !$0.cards.isEmpty })?.cards.first
        case "search":
            model.isShowingSearch = true
        default:
            break
        }
    }
}
