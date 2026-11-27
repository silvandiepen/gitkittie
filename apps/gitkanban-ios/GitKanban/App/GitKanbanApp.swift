import BackgroundTasks
import Network
import SwiftUI
import GitKanbanKit
import GitKittieKit
import UIKit

@main
struct GitKanbanApp: App {
    @State private var model = AppModel.shared(migratesLegacyStorage: true)
    @State private var network = NetworkWatcher()
    @Environment(\.scenePhase) private var scenePhase

    /// The background refresh that sends whatever is still in the outbox.
    private static let syncTask = "app.hakobs.gitkanban.sync"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                #if DEBUG
                .task { ShareSheetProbe.presentIfRequested() }
                .task {
                    // `-aiDiagnostics`: say what the on-device model answers on this device.
                    guard ProcessInfo.processInfo.arguments.contains("-aiDiagnostics") else { return }
                    print("AI-DIAG available=\(OnDeviceAI.isAvailable) reason=\(OnDeviceAI.unavailableReason ?? "none")")
                    print("AI-DIAG \(OnDeviceAI.diagnostics)")
                    print("AI-DIAG provider=\(model.aiProvider) imageProvider=\(String(describing: model.imageAnalysisProvider)) locale=\(Locale.current.identifier) languages=\(Locale.preferredLanguages)")
                    let context = AITicketContext(projectName: "GitKittie", lanes: ["To do"], priorities: ["P0", "P1", "P2", "P3"],
                                                  types: ["feature", "fix", "chore"], epics: [], existingTicketTitles: [])
                    let input = "A screenshot belongs to these notes, but you cannot see it.\n\nNotes the person wrote on the screenshot, each pointing at something in it:\n1. Make this just an edit button.\n2. Title is still the first comment."
                    let started = Date()
                    do {
                        let ticket = try await OnDeviceAI.draftTicket(input: input, context: context)
                        print("AI-DIAG draft ok in \(Date().timeIntervalSince(started)) s: \(ticket.title) || \(ticket.description.replacingOccurrences(of: "\n", with: " / "))")
                    } catch {
                        print("AI-DIAG draft FAILED in \(Date().timeIntervalSince(started)) s: \(error) || \(error.localizedDescription)")
                    }
                    print("AI-DIAG done")
                }
                #endif
                // `gitkittie-tasks://new?…`: another app's Make Task (GitKittie Mail, GKM-033).
                .onOpenURL { url in model.openTaskRequest(url) }
                .tint(Theme.accent)
                .preferredColorScheme(CaptureHooks.colorScheme ?? .dark)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // The share extension may have saved changes while the app was away.
                        Task { await model.refreshSyncItems(); await model.flushOutbox() }
                    case .background:
                        finishSendingInBackground()
                        scheduleNewsCheck()
                    default:
                        break
                    }
                }
                .onChange(of: network.isOnline) { _, online in
                    if online { Task { await model.flushOutbox() } }
                }
                .task {
                    // Test hook: launch with GITKANBAN_DEMO=1 to open the offline demo.
                    if CaptureHooks.isDemo {
                        await model.loadDemo()
                        CaptureHooks.applyRoute(to: model)
                    } else {
                        await model.restore()
                        await model.startNotifications()
                    }
                }
                .task {
                    // While the app is open: look for new reviews every few minutes.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(240))
                        if scenePhase == .active, model.wantsBackgroundChecks { await model.checkForNews() }
                    }
                }
        }
        .backgroundTask(.appRefresh(Self.syncTask)) {
            await model.refreshSyncItems()
            await model.flushOutbox()
            // The same wake-up looks for reviews to announce, and asks for the next one.
            await model.startNotifications()
            if await model.wantsBackgroundChecks {
                await model.checkForNews()
                await MainActor.run { Self.submitNewsCheck() }
            }
        }
    }

    /// Ask iOS to wake the app now and then to look for news. It decides when.
    private func scheduleNewsCheck() {
        guard model.wantsBackgroundChecks else { return }
        Self.submitNewsCheck()
    }

    private static func submitNewsCheck() {
        let request = BGAppRefreshTaskRequest(identifier: syncTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Leaving the app with changes still unsent: keep going for the time iOS allows, and
    /// ask to be woken later in case that was not enough (or there is no connection).
    private func finishSendingInBackground() {
        guard !model.syncItems.isEmpty else { return }
        var token = UIBackgroundTaskIdentifier.invalid
        token = UIApplication.shared.beginBackgroundTask(withName: "Send changes") {
            UIApplication.shared.endBackgroundTask(token)
            token = .invalid
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.syncTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
        Task {
            await model.flushOutbox()
            if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
        }
    }
}

/// Whether the device currently has a network path, to send the outbox when it returns.
@MainActor
@Observable
final class NetworkWatcher {
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "app.hakobs.gitkanban.network"))
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
