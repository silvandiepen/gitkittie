import SwiftUI

@main
struct GitFolderApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(CaptureHooks.colorScheme)
                .task {
                    // Test hook: launch with GITFOLDER_DEMO=1 to open the offline demo.
                    if CaptureHooks.isDemo {
                        model.loadDemo()
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
/// same appearance, same screen. Every hook is a no-op when its variable is unset, so a
/// normal launch behaves exactly as before.
enum CaptureHooks {
    private static let environment = ProcessInfo.processInfo.environment

    /// `GITFOLDER_DEMO=1` — load the offline demo instead of restoring a session.
    static var isDemo: Bool { environment["GITFOLDER_DEMO"] == "1" }

    /// `GITFOLDER_APPEARANCE=light|dark` — pin the appearance so both variants are
    /// reproducible rather than following the simulator's current setting.
    static var colorScheme: ColorScheme? {
        switch environment["GITFOLDER_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// `GITFOLDER_DEMO_OPEN=<owner/repo>` — open one of the demo repos straight away
    /// instead of stopping on the repo list.
    @MainActor
    static func applyRoute(to model: AppModel) {
        guard let open = environment["GITFOLDER_DEMO_OPEN"],
              let ref = model.addedRepos.first(where: { $0.fullName == open }) else { return }
        model.openRepo(ref)
    }
}
