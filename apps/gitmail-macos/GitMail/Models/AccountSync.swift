import Foundation
import MailAccounts
import MailCore
import MailProvider
import MailStore
import MailSync
import Observation

/// What account setup and sync need from the outside world: the Keychain, how to connect, how
/// to sync, and where preferences live. `.live` is the app; tests pass the local test server's
/// trust and a test Keychain service, nothing faked.
struct AccountServices {
    var credentials: KeychainCredentialStore
    var connections: AccountConnections
    var verifier: AccountVerifier
    var syncOptions: SyncOptions
    var defaults: UserDefaults

    static var live: AccountServices {
        var options = SyncOptions()
        // Attachments above this stay at the provider until opened or pinned (GKM-036); 1 MB
        // unless set (`defaults write app.hakobs.gitmail onDemandThresholdBytes <bytes>`, 0 = off).
        if let threshold = UserDefaults.standard.object(forKey: "onDemandThresholdBytes") as? Int {
            options.onDemandThreshold = threshold > 0 ? threshold : nil
        }
        return AccountServices(
            credentials: KeychainCredentialStore(),
            connections: AccountConnections(),
            verifier: AccountVerifier(),
            syncOptions: options,
            defaults: .standard)
    }
}

/// Each connected account's sync: one ``SyncCoordinator`` per account, its progress as the
/// window shows it, and the provider's folders for the sidebar (GKM-011).
@MainActor
@Observable
final class AccountSync {
    /// The newest progress of each account's sync.
    private(set) var progress: [MailAccountID: SyncProgress] = [:]
    /// Each account's folders at the provider, in the provider's order.
    private(set) var folders: [MailAccountID: [SyncedFolder]] = [:]
    /// Each account's action replay: what is waiting to reach the provider (GKM-015).
    private(set) var replay: [MailAccountID: ReplayProgress] = [:]

    @ObservationIgnored private var coordinators: [MailAccountID: SyncCoordinator] = [:]
    @ObservationIgnored private var listeners: [MailAccountID: Task<Void, Never>] = [:]
    @ObservationIgnored private var replayers: [MailAccountID: ActionReplayer] = [:]
    @ObservationIgnored private var replayListeners: [MailAccountID: Task<Void, Never>] = [:]
    /// Each account's on-demand fetcher: attachments left at the provider, pins (GKM-036).
    @ObservationIgnored private var fetchers: [MailAccountID: OnDemandFetcher] = [:]
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored let services: AccountServices
    /// Called (coalesced) when synced mail changed what the window shows.
    @ObservationIgnored var onStoreChanged: (@MainActor () async -> Void)?

    init(services: AccountServices) {
        self.services = services
    }

    var isRunning: Bool { !coordinators.isEmpty }

    func isSyncing(_ account: MailAccountID) -> Bool { coordinators[account] != nil }

    /// Starts syncing every connected account that has its password on this device; reads the
    /// folders last seen for all of them, so the sidebar has them before the first connect.
    func start(_ accounts: [MailAccount], store: MailStore) async {
        for account in accounts {
            folders[account.id] = (try? await store.syncedFolders(account: account.id)) ?? []
            guard account.connection != nil, coordinators[account.id] == nil else { continue }
            await start(account, store: store)
        }
    }

    /// Starts one account's sync. Without a password on this device (a folder from another
    /// Mac, or a removed Keychain item) it says so instead.
    func start(_ account: MailAccount, store: MailStore) async {
        guard let connection = account.connection, coordinators[account.id] == nil else { return }
        let secret: Secret?
        do {
            secret = try services.credentials.secret(for: account.id)
        } catch {
            progress[account.id] = Self.signInNeeded(String(describing: error))
            return
        }
        guard let secret else {
            progress[account.id] = Self.signInNeeded("This Mac has no password for this account yet.")
            return
        }
        let connector = services.connections.imap(connection, password: secret)
        let coordinator = SyncCoordinator(account: account.id, connector: connector,
                                          store: store, options: services.syncOptions, log: services.connections.log)
        coordinators[account.id] = coordinator
        let id = account.id
        // Everyday actions go over their own connection, so a flag never waits for an import.
        let replayer = ActionReplayer(account: id, connector: connector, store: store,
                                      reconnect: services.syncOptions.reconnect, log: services.connections.log)
        replayers[id] = replayer
        // Attachments on demand use a connection of their own too.
        fetchers[id] = OnDemandFetcher(account: id, connector: connector, store: store, log: services.connections.log)
        replayListeners[id] = Task { [weak self] in
            for await update in replayer.updates {
                guard let self else { return }
                self.receive(update, for: id)
            }
        }
        await replayer.start()
        listeners[id] = Task { [weak self] in
            for await update in coordinator.updates {
                guard let self else { return }
                self.receive(update, for: id)
            }
        }
        await coordinator.start()
    }

    /// Stops one account's sync and waits for its connection to close.
    func stop(_ account: MailAccountID) async {
        if let coordinator = coordinators.removeValue(forKey: account) { await coordinator.stop() }
        listeners.removeValue(forKey: account)?.cancel()
        if let replayer = replayers.removeValue(forKey: account) { await replayer.stop() }
        fetchers[account] = nil
        replayListeners.removeValue(forKey: account)?.cancel()
        progress[account] = nil
        replay[account] = nil
    }

    /// Actions were queued for these accounts: send them now (GKM-015).
    func actionsQueued(for accounts: [MailAccountID]) async {
        for account in accounts {
            guard let replayer = replayers[account] else { continue }
            await replayer.refreshStatus()
            await replayer.kick()
        }
    }

    /// The on-demand fetcher of a syncing account; nil when it does not sync on this Mac.
    func fetcher(for account: MailAccountID) -> OnDemandFetcher? { fetchers[account] }

    /// The replayer of an account, for tests.
    func replayer(for account: MailAccountID) -> ActionReplayer? { replayers[account] }

    func stopAll() async {
        for id in Array(coordinators.keys) { await stop(id) }
        folders = [:]
    }

    /// The folder the person is looking at, so its account waits on it.
    func setActiveFolder(_ folder: String?, account: MailAccountID) async {
        await coordinators[account]?.setActiveFolder(folder)
    }

    func syncNow() async {
        for coordinator in coordinators.values { await coordinator.syncNow() }
    }

    func forget(_ account: MailAccountID) {
        folders[account] = nil
        progress[account] = nil
        replay[account] = nil
    }

    // MARK: Updates

    private func receive(_ update: SyncProgress, for account: MailAccountID) {
        let previous = progress[account]
        progress[account] = update
        if !update.folders.isEmpty, update.folders != folders[account] { folders[account] = update.folders }
        let changed = previous == nil || previous?.imported != update.imported || previous?.folders != update.folders
            || previous?.lastCompletedPass != update.lastCompletedPass
        if changed { scheduleRefresh() }
        // The sync reached the provider: queued actions can go now instead of at their backoff.
        if previous?.lastCompletedPass != update.lastCompletedPass || (previous.map(Self.isOffline) == true && !Self.isOffline(update)) {
            if let replayer = replayers[account] { Task { await replayer.kick() } }
        }
    }

    private func receive(_ update: ReplayProgress, for account: MailAccountID) {
        let previous = replay[account]
        replay[account] = update
        // A row settled or was overtaken: the list shows the provider's state now.
        if previous?.status.pending != update.status.pending || previous?.status.recentlySuperseded != update.status.recentlySuperseded {
            scheduleRefresh()
        }
    }

    private static func isOffline(_ progress: SyncProgress) -> Bool {
        if case .waitingToRetry = progress.activity { return true }
        return false
    }

    /// Coalesces refreshes: an import of a thousand messages refreshes the list a few times a
    /// second, not a thousand times.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.refreshPending = false
            await self.onStoreChanged?()
        }
    }

    private static func signInNeeded(_ reason: String) -> SyncProgress {
        var progress = SyncProgress()
        progress.activity = .signInFailed(reason: reason)
        return progress
    }
}

/// How an account's sync reads in the sidebar: short, plain, and never "up to date" while
/// mail is still coming in.
enum SyncStatusText {
    static func line(_ progress: SyncProgress?, now: Date = Date()) -> String? {
        guard let progress else { return nil }
        switch progress.activity {
        case .starting, .connecting:
            return progress.imported == 0 ? "Connecting…" : "Reconnecting…"
        case .importing:
            if progress.remaining > 0 { return "Downloading · \(progress.remaining.formatted()) to go" }
            return "Downloading…"
        case .checking:
            return progress.remaining > 0 ? "Downloading · \(progress.remaining.formatted()) to go" : "Checking for changes…"
        case .watching:
            if progress.historyPausedForBudget { return "Up to date · older mail paused at the storage limit" }
            if progress.remaining > 0 { return "\(progress.remaining.formatted()) older messages to go" }
            return "Up to date"
        case .waitingToRetry(_, let retryAt):
            let seconds = max(0, Int(retryAt.timeIntervalSince(now).rounded()))
            return seconds > 1 ? "Offline · trying again in \(seconds) s" : "Offline · trying again"
        case .signInFailed:
            return "Password needed"
        case .stopped:
            return nil
        }
    }

    static func needsPassword(_ progress: SyncProgress?) -> Bool {
        if case .signInFailed = progress?.activity { return true }
        return false
    }
}
