import BackgroundTasks
import UIKit

/// `UIApplication.beginBackgroundTask`: the time iOS gives an app that just left the screen.
struct ApplicationBackgroundTasks: BackgroundTaskRunning {
    func begin(_ name: String, expiration: @escaping @MainActor () -> Void) -> Int {
        let task = BackgroundTaskID()
        task.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                expiration()
                UIApplication.shared.endBackgroundTask(task.id)
            }
        }
        return task.id.rawValue
    }

    func end(_ id: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
    }
}

/// The identifier iOS hands back, for the expiration handler that has to end it.
@MainActor
private final class BackgroundTaskID {
    var id = UIBackgroundTaskIdentifier.invalid
}

/// The two background tasks (MAIL-053). iOS decides when, and whether, either runs: nothing in
/// the app promises a time. Both are asked for again every time the app leaves the screen.
enum MailBackgroundTasks {
    static let refresh = "app.hakobs.gitmail.refresh"
    static let processing = "app.hakobs.gitmail.processing"

    /// Registers the handlers. Must run before the app finishes launching.
    @MainActor
    static func register(_ session: MobileSession) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refresh, using: .main) { task in
            MainActor.assumeIsolated { run(task, session: session) { await session.backgroundRefresh() } }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processing, using: .main) { task in
            MainActor.assumeIsolated { run(task, session: session) { await session.backgroundProcessing() } }
        }
    }

    /// Asks for the next check in about 15 minutes, and a catch-up when the phone is charging.
    /// Returns why iOS refused, in words, or nil.
    @discardableResult
    static func schedule() -> String? {
        let refreshRequest = BGAppRefreshTaskRequest(identifier: refresh)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        let processingRequest = BGProcessingTaskRequest(identifier: processing)
        processingRequest.requiresNetworkConnectivity = true
        processingRequest.requiresExternalPower = true
        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
            try BGTaskScheduler.shared.submit(processingRequest)
            return nil
        } catch let error as BGTaskScheduler.Error {
            switch error.code {
            case .unavailable: return "Background App Refresh is off for Mail, or this device can’t run it."
            case .notPermitted: return "Mail isn’t allowed to run in the background."
            case .tooManyPendingTaskRequests: return nil // the earlier requests still stand
            default: return "iOS didn’t accept the background check (\(error.code.rawValue))."
            }
        } catch {
            return "iOS didn’t accept the background check: \(error.localizedDescription)"
        }
    }

    @MainActor
    private static func run(_ task: BGTask, session: MobileSession, _ work: @escaping @MainActor () async -> BackgroundRun) {
        // The next one first, so a task that is cut short still leaves one asked for.
        session.backgroundNotice = schedule()
        let running = Task { @MainActor in
            let run = await work()
            task.setTaskCompleted(success: !run.cutShort)
        }
        task.expirationHandler = { running.cancel() }
    }
}
