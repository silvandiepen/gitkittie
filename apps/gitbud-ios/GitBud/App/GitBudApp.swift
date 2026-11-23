import SwiftUI

@main
struct GitBudApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task {
                    if CaptureHooks.isDemo {
                        await model.loadDemo()
                        CaptureHooks.apply(to: model)
                    } else {
                        await model.restore()
                    }
                }
        }
    }
}

/// Launch hooks for screenshots and UI tests, like Tasks' own. Each is a no-op when unset.
///
/// - `GITBUD_DEMO=1` opens the offline demo instead of restoring a session.
/// - `GITBUD_COMMIT=<sha prefix or subject words>` opens that commit.
/// - `GITBUD_FILE=<path>` then opens that file of it; `GITBUD_DIFF_MODE=unified|sideBySide|fullFile`.
enum CaptureHooks {
    private static let environment = ProcessInfo.processInfo.environment

    static var isDemo: Bool { environment["GITBUD_DEMO"] == "1" }
    static var file: String? { environment["GITBUD_FILE"] }
    static var diffMode: DiffMode? { environment["GITBUD_DIFF_MODE"].flatMap(DiffMode.init(rawValue:)) }

    @MainActor
    static func apply(to model: AppModel) {
        guard let wanted = environment["GITBUD_COMMIT"], !wanted.isEmpty else { return }
        model.selectedCommitSHA = model.commits.first {
            $0.sha.hasPrefix(wanted) || $0.subject.localizedCaseInsensitiveContains(wanted)
        }?.sha
    }
}
