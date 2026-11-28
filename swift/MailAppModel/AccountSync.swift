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
    /// The most the offline cache of attachments keeps (GKM-036); `nil` takes the Mac's default.
    /// The iPhone sets its storage budget's cache here (MAIL-079).
    var offlineCacheBytes: Int64? = nil
    /// Free space on the disk that holds a folder (MAIL-106); tests pass a value of their own.
    /// The sync's own floor reads it too (GKM-091), from its actor, so it is `@Sendable`.
    var freeSpace: @Sendable (URL) -> Int64? = FreeSpace.available(at:)
    /// Under this much free space downloading pauses (MAIL-106): 2 GB on the Mac, the storage
    /// budget's minimum on the iPhone and iPad (MAIL-051). The one number: the sync's floor and
    /// the store's check are this minimum too (GKM-091, MAIL-123).
    var minimumFreeBytes: Int64 = DownloadPause.macMinimumFreeBytes
    /// How often a running sync looks at the free space besides as mail comes in; also how
    /// often a sync stopped on this device (paused for space, store not writable) looks again.
    var freeSpaceCheckInterval: Duration = .seconds(60)
    /// Where a mail folder is (GKM-103, MAIL-126): in iCloud Drive or a File Provider folder the
    /// sync doesn't start. Tests pass a placement of their own.
    var folderPlacement: @Sendable (URL) -> MailFolderPlacement = MailFolderPlacement.of(_:)

    /// The sync's floor (GKM-091): the minimum and the free-space reader above.
    var freeSpaceFloor: FreeSpaceFloor {
        FreeSpaceFloor(minimumFreeBytes: minimumFreeBytes, available: freeSpace)
    }

    static var live: AccountServices {
        var options = SyncOptions()
        // Attachments above this stay at the provider until opened or pinned (GKM-036); 1 MB
        // unless set (`defaults write app.hakobs.gitmail onDemandThresholdBytes <bytes>`, 0 = off).
        if let threshold = UserDefaults.standard.object(forKey: AppModel.onDemandThresholdKey) as? Int {
            options.onDemandThreshold = threshold > 0 ? threshold : nil
        }
        // How far back a folder's history goes (MAIL-072): the Mac's Offline Storage window
        // sets it; absent or 0 is all of it. The iPhone app sets its own from its budget.
        options.historyDays = AccountServices.historyDays(in: .standard)
        return AccountServices(
            credentials: KeychainCredentialStore(),
            connections: AccountConnections(),
            verifier: AccountVerifier(),
            syncOptions: options,
            defaults: .standard)
    }
}

extension AccountServices {
    static let historyDaysKey = "historyDays"

    /// The history window saved in `defaults`; nil (no window) when unset or 0.
    static func historyDays(in defaults: UserDefaults) -> Int? {
        let days = defaults.integer(forKey: historyDaysKey)
        return days > 0 ? days : nil
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
    /// Set while downloading is paused because the mail folder's disk is nearly full (MAIL-106);
    /// says so in words. Nil when there is room.
    private(set) var downloadPause: DownloadPause?
    /// Set while the sync is held back because the mail folder is in iCloud Drive or a folder
    /// another app syncs (GKM-103, MAIL-126): nothing starts, not even actions, until another
    /// folder is chosen. Nil for a folder on this device.
    private(set) var folderHold: MailFolderPlacement?

    @ObservationIgnored private var coordinators: [MailAccountID: SyncCoordinator] = [:]
    /// Every account this sync was started for, downloading or paused for space, as it was
    /// started: a pause and its resume keep the account's settings.
    @ObservationIgnored private var started: [MailAccountID: MailAccount] = [:]
    @ObservationIgnored private var listeners: [MailAccountID: Task<Void, Never>] = [:]
    @ObservationIgnored private var replayers: [MailAccountID: ActionReplayer] = [:]
    @ObservationIgnored private var replayListeners: [MailAccountID: Task<Void, Never>] = [:]
    /// Each account's on-demand fetcher: attachments left at the provider, pins (GKM-036).
    @ObservationIgnored private var fetchers: [MailAccountID: OnDemandFetcher] = [:]
    /// Each account's server search: mail left at the provider (GKM-041).
    @ObservationIgnored private var searchers: [MailAccountID: ServerSearcher] = [:]
    @ObservationIgnored private var refreshPending = false
    /// The store the sync writes into, for the free space checks.
    @ObservationIgnored private var store: MailStore?
    @ObservationIgnored private var spaceWatch: Task<Void, Never>?
    @ObservationIgnored private var lastSpaceCheck: ContinuousClock.Instant?
    @ObservationIgnored private var reviewingSpace = false
    /// Settable so the iPhone app can apply a changed storage budget (`syncOptions`) to the next
    /// start; a running sync keeps the options it started with.
    @ObservationIgnored var services: AccountServices
    /// Called (coalesced) when synced mail changed what the window shows.
    @ObservationIgnored var onStoreChanged: (@MainActor () async -> Void)?

    init(services: AccountServices) {
        self.services = services
    }

    /// True while some account is downloading (not paused for space, not stopped).
    var isRunning: Bool { !coordinators.isEmpty }

    /// True when the account syncs on this device: downloading, or paused for space.
    func isSyncing(_ account: MailAccountID) -> Bool { started[account] != nil }

    /// True when the account's downloading is paused because the disk is nearly full (MAIL-106):
    /// stopped by this sync's check, or by the sync's own floor (GKM-091).
    func isPausedForSpace(_ account: MailAccountID) -> Bool {
        guard started[account] != nil else { return false }
        return coordinators[account] == nil || progress[account].map(Self.isPausedForSpace) == true
    }

    /// Starts syncing every connected account that has its password on this device; reads the
    /// folders last seen for all of them, so the sidebar has them before the first connect.
    /// Under the minimum free space nothing downloads, and it says so (MAIL-106); the free
    /// space is looked at again as mail comes in and once a minute.
    func start(_ accounts: [MailAccount], store: MailStore) async {
        guard !isHeld(store) else {
            for account in accounts { folders[account.id] = (try? await store.syncedFolders(account: account.id)) ?? [] }
            return
        }
        self.store = store
        _ = hasRoom()
        watchFreeSpace()
        for account in accounts {
            folders[account.id] = (try? await store.syncedFolders(account: account.id)) ?? []
            guard account.connection != nil, started[account.id] == nil else { continue }
            await start(account, store: store)
        }
    }

    /// Starts one account's sync. Without a password on this device (a folder from another
    /// Mac, or a removed Keychain item) it says so instead. Actions, attachments on demand and
    /// server search start whatever the free space; downloading only when there is room.
    func start(_ account: MailAccount, store: MailStore) async {
        guard started[account.id] == nil, !isHeld(store), let connector = connector(for: account) else { return }
        self.store = store
        let id = account.id
        started[id] = account
        // Everyday actions go over their own connection, so a flag never waits for an import.
        let replayer = ActionReplayer(account: id, connector: connector, store: store,
                                      reconnect: services.syncOptions.reconnect, log: services.connections.log)
        replayers[id] = replayer
        // Attachments on demand use a connection of their own too.
        fetchers[id] = OnDemandFetcher(account: id, connector: connector, store: store, log: services.connections.log)
        // Searching the provider and opening what it found: one more connection, at most (MAIL-082).
        searchers[id] = ServerSearcher(account: id, connector: connector, store: store,
                                       onDemandThreshold: services.syncOptions.onDemandThreshold, log: services.connections.log)
        replayListeners[id] = Task { [weak self] in
            for await update in replayer.updates {
                guard let self else { return }
                self.receive(update, for: id)
            }
        }
        await replayer.start()
        if hasRoom() { await startDownloading(account, connector: connector, store: store) }
        if spaceWatch == nil { watchFreeSpace() }
    }

    /// True, with `folderHold` set, when the store's mail folder is somewhere the sync must not
    /// write (GKM-103): checked on every start, so no start path can get around it.
    private func isHeld(_ store: MailStore) -> Bool {
        checkPlacement(of: store.locations.mailFolder) != nil
    }

    /// Where `folder` is, as the hold: set (and returned) when it is somewhere nothing may be
    /// written, cleared when it is not. The app model asks before it opens the store, so the
    /// store opens read-only (GKM-104, MAIL-135).
    @discardableResult
    func checkPlacement(of folder: URL) -> MailFolderPlacement? {
        let placement = services.folderPlacement(folder)
        folderHold = placement.isSafe ? nil : placement
        return folderHold
    }

    /// The account's IMAP connector with its password; nil, with the account's status saying
    /// why, when this device has no password for it.
    private func connector(for account: MailAccount) -> (any MailboxConnector)? {
        guard let connection = account.connection else { return nil }
        let secret: Secret?
        do {
            secret = try services.credentials.secret(for: account.id)
        } catch {
            progress[account.id] = Self.signInNeeded(String(describing: error))
            return nil
        }
        guard let secret else {
            progress[account.id] = Self.signInNeeded("\(DeviceWords.thisAtStart) has no password for this account yet.")
            return nil
        }
        return services.connections.imap(connection, password: secret)
    }

    /// Starts the account's download coordinator: folders, new mail, history, IDLE.
    private func startDownloading(_ account: MailAccount, connector: any MailboxConnector, store: MailStore) async {
        let id = account.id
        // Stopped meanwhile (a resume and a stop can cross at an await): it stays stopped.
        guard coordinators[id] == nil, started[id] != nil else { return }
        var options = services.syncOptions
        options.removesMailDeletedElsewhere = account.removesDeletedMail
        options.mailboxes = account.mailboxSettings
        // The floor inside the sync and the store (GKM-091): the same minimum as the pause, so a
        // sync between this model's checks still stops before the disk fills.
        options.freeSpaceFloor = services.freeSpaceFloor
        options.localStopRecheck = services.freeSpaceCheckInterval
        let coordinator = SyncCoordinator(account: id, connector: connector,
                                          store: store, options: options, log: services.connections.log)
        coordinators[id] = coordinator
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
        // Stop listening first: the coordinator's last update (stopped) still carries the folders
        // as it last recorded them, which must not overwrite folders changed meanwhile (GKM-066).
        listeners.removeValue(forKey: account)?.cancel()
        started[account] = nil
        if let coordinator = coordinators.removeValue(forKey: account) { await coordinator.stop() }
        if let replayer = replayers.removeValue(forKey: account) { await replayer.stop() }
        fetchers[account] = nil
        searchers[account] = nil
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

    /// Folders on record changed outside a sync pass (settings, a folder edit): show them now.
    func setFolders(_ folders: [SyncedFolder], for account: MailAccountID) {
        self.folders[account] = folders
    }

    /// Edits the account's folders at the provider (GKM-066), over a connection of its own with
    /// the password in the Keychain. The caller stops the account's sync first.
    func folderEditor(for account: MailAccount, store: MailStore) throws -> FolderEditor {
        guard let connection = account.connection else {
            throw MailProviderError.unsupported("this account isn’t connected")
        }
        guard let secret = try services.credentials.secret(for: account.id) else {
            throw MailProviderError.authenticationFailed("\(DeviceWords.thisAtStart) has no password for this account yet.")
        }
        return FolderEditor(account: account.id, connector: services.connections.imap(connection, password: secret), store: store,
                            log: services.connections.log)
    }

    /// The on-demand fetcher of a syncing account; nil when it does not sync on this Mac.
    func fetcher(for account: MailAccountID) -> OnDemandFetcher? { fetchers[account] }

    // MARK: Searching the server (GKM-041)

    /// True when the sync leaves mail at the provider by design (a history window or a storage
    /// budget) and an account in scope (all when nil) has a folder whose history is not all
    /// here. Without either limit (the Mac's default) everything comes down, so there is
    /// nothing to search for at the provider.
    func leavesMailOnServer(account: MailAccountID?) -> Bool {
        !searchableAccounts(account).isEmpty
    }

    /// True when every account the search would ask is offline: the last connection attempt
    /// failed and the sync waits to retry.
    func isOffline(account: MailAccountID?) -> Bool {
        let accounts = searchableAccounts(account)
        return !accounts.isEmpty && accounts.allSatisfy { progress[$0].map(Self.isOffline) == true }
    }

    /// Searches the provider of each account in scope that leaves mail there, at the same time
    /// (each on its one search connection), and merges what they found, newest first.
    func searchServer(_ query: ServerQuery) async -> ServerSearchState {
        let accounts = searchableAccounts(query.account).compactMap { id in searchers[id] }
        guard !accounts.isEmpty else { return .off }
        let outcomes = await withTaskGroup(of: Result<ServerSearchResult, any Error>.self) { group in
            for searcher in accounts {
                group.addTask {
                    do { return .success(try await searcher.search(query.criteria, mailbox: query.mailbox)) } catch { return .failure(error) }
                }
            }
            var outcomes: [Result<ServerSearchResult, any Error>] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        var hits: [ServerSearchHit] = []
        var total = 0
        var failures: [any Error] = []
        for outcome in outcomes {
            switch outcome {
            case .success(let result):
                hits += result.hits
                total += result.total
            case .failure(let error):
                failures.append(error)
            }
        }
        guard failures.count < outcomes.count else {
            if failures.contains(where: { if case ServerSearcher.Failure.offline = $0 { true } else { false } }) { return .offline }
            let failure = failures[0]
            return .failed((failure as? ServerSearcher.Failure)?.description ?? String(describing: failure))
        }
        hits.sort { ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast) }
        return .found(Array(hits.prefix(ServerSearcher.defaultLimit)), total: total)
    }

    /// Downloads a message the server search found and stores it like synced mail (GKM-041).
    func downloadServerHit(_ hit: ServerSearchHit) async throws -> MailMessageID {
        guard let searcher = searchers[hit.account] else {
            throw ServerSearcher.Failure.failed("this account doesn’t sync on \(DeviceWords.this)")
        }
        let id = try await searcher.download(hit)
        scheduleRefresh() // counts and the sidebar
        return id
    }

    /// Syncing accounts in scope that leave mail at the provider, in a stable order.
    private func searchableAccounts(_ account: MailAccountID?) -> [MailAccountID] {
        let options = services.syncOptions
        guard options.historyDays != nil || options.historyBudgetBytes != nil else { return [] }
        return searchers.keys.filter { id in
            (account == nil || account == id) && folders[id]?.contains { !$0.historyComplete && $0.uidValidity != nil } == true
        }.sorted { $0.rawValue < $1.rawValue }
    }

    /// The replayer of an account, for tests.
    func replayer(for account: MailAccountID) -> ActionReplayer? { replayers[account] }

    func stopAll() async {
        spaceWatch?.cancel()
        spaceWatch = nil
        for id in Array(started.keys) { await stop(id) }
        folders = [:]
        downloadPause = nil
        folderHold = nil
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

    // MARK: Free space (MAIL-106)

    /// Looks at the free space on the mail folder's disk: pauses every download under the
    /// minimum, and starts the paused ones again when there is room. The watch calls it once a
    /// minute and as mail comes in; Settings calls it after freeing space.
    func reviewFreeSpace() async {
        guard let store, !reviewingSpace else { return }
        reviewingSpace = true
        defer { reviewingSpace = false }
        if hasRoom() {
            for (id, account) in started.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where coordinators[id] == nil {
                guard let connector = connector(for: account) else { continue }
                await startDownloading(account, connector: connector, store: store)
            }
        } else {
            for id in Array(coordinators.keys) {
                // The account stays started (actions, attachments, search); only downloading stops.
                listeners.removeValue(forKey: id)?.cancel()
                if let coordinator = coordinators.removeValue(forKey: id) { await coordinator.stop() }
            }
        }
    }

    /// True when the mail folder's disk has the minimum free; sets or clears `downloadPause`.
    /// A disk whose free space can't be read is taken to have room. With room, a download that
    /// its own floor paused (GKM-091: a batch would have gone under the minimum) still shows the
    /// pause until it carries on.
    private func hasRoom() -> Bool {
        lastSpaceCheck = .now
        guard let store, let free = services.freeSpace(store.locations.mailFolder), free < services.minimumFreeBytes else {
            show(floorPause)
            return true
        }
        show(DownloadPause(freeBytes: free, minimumFreeBytes: services.minimumFreeBytes))
        return false
    }

    /// The pause a running download's floor reported, if any (GKM-091).
    private var floorPause: DownloadPause? {
        coordinators.keys.sorted { $0.rawValue < $1.rawValue }.lazy.compactMap { id -> DownloadPause? in
            guard case .pausedForSpace(let free, let minimum) = self.progress[id]?.activity else { return nil }
            return DownloadPause(freeBytes: free, minimumFreeBytes: minimum)
        }.first
    }

    private func show(_ pause: DownloadPause?) {
        guard let pause else {
            downloadPause = nil
            return
        }
        // The text gives the free space in tenths of a GB: a few bytes more or less is no news.
        if downloadPause.map({ DownloadPause.amount($0.freeBytes) != DownloadPause.amount(pause.freeBytes) }) ?? true {
            downloadPause = pause
        }
    }

    /// Checks again at once when the last check is more than a few seconds old.
    private func checkFreeSpaceSoon() {
        if let last = lastSpaceCheck, ContinuousClock.now - last < .seconds(5) { return }
        lastSpaceCheck = .now
        Task { [weak self] in await self?.reviewFreeSpace() }
    }

    /// While the sync runs, looks at the free space every `freeSpaceCheckInterval`.
    private func watchFreeSpace() {
        spaceWatch?.cancel()
        let interval = services.freeSpaceCheckInterval
        spaceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.reviewFreeSpace()
            }
        }
    }

    // MARK: Updates

    private func receive(_ update: SyncProgress, for account: MailAccountID) {
        let previous = progress[account]
        progress[account] = update
        if !update.folders.isEmpty, update.folders != folders[account] { folders[account] = update.folders }
        let changed = previous == nil || previous?.imported != update.imported || previous?.folders != update.folders
            || previous?.lastCompletedPass != update.lastCompletedPass
        if changed { scheduleRefresh() }
        // Mail came in: a fast first sync can fill gigabytes between the minute's checks.
        if previous?.imported != update.imported { checkFreeSpaceSoon() }
        // The sync's own floor paused it, or it carries on (GKM-091): the pause shows as the
        // MAIL-106 pause, with the same words, never as offline.
        if Self.isPausedForSpace(update) || previous.map(Self.isPausedForSpace) == true {
            lastSpaceCheck = nil
            checkFreeSpaceSoon()
        }
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

    private static func isPausedForSpace(_ progress: SyncProgress) -> Bool {
        if case .pausedForSpace = progress.activity { return true }
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
            if progress.olderNotDownloaded > 0, let days = progress.historyDays {
                return "Up to date · older than \(days) days not downloaded"
            }
            return "Up to date"
        case .waitingToRetry(_, let retryAt):
            let seconds = max(0, Int(retryAt.timeIntervalSince(now).rounded()))
            return seconds > 1 ? "Offline · trying again in \(seconds) s" : "Offline · trying again"
        case .signInFailed:
            return "Password needed"
        case .pausedForSpace:
            return DownloadPause.shortText
        case .cannotStore(let problem, _):
            return "Can’t save mail · " + LocalStopText.what(problem)
        case .stopped:
            return nil
        }
    }

    /// What to do about a stop on this device, as a second line under ``line(_:now:)``; nil
    /// when the status says it all.
    static func advice(_ progress: SyncProgress?) -> String? {
        guard case .cannotStore(let problem, _) = progress?.activity else { return nil }
        return LocalStopText.advice(problem)
    }

    static func needsPassword(_ progress: SyncProgress?) -> Bool {
        if case .signInFailed = progress?.activity { return true }
        return false
    }
}

/// Plain words for a sync that stopped because of this device, not the network (GKM-091,
/// MAIL-124): what happened, then what to do. Mail already stored is never touched by it.
enum LocalStopText {
    /// After "Can’t save mail · ".
    static func what(_ problem: LocalStoreProblem) -> String {
        switch problem {
        case .diskFull: "\(DeviceWords.this) is out of space"
        case .notWritable: "the mail folder is read-only"
        case .folderUnavailable: "the mail folder can’t be found"
        case .damaged: "Mail’s records on \(DeviceWords.this) are damaged"
        }
    }

    static func advice(_ problem: LocalStoreProblem) -> String {
        switch problem {
        case .diskFull:
            "Free some space and it carries on by itself."
        case .notWritable:
            "Give yourself permission to write to it again and it carries on by itself."
        case .folderUnavailable:
            #if os(macOS)
            "Reconnect the disk it is on, or choose the folder again in Settings ▸ Storage. It carries on by itself when it’s back."
            #else
            "It carries on by itself when the folder is back."
            #endif
        case .damaged:
            #if os(macOS)
            "Your mail files are not affected. Choose View ▸ Rebuild Search Index; it tries again by itself."
            #else
            "Your mail files are not affected. It tries again by itself."
            #endif
        }
    }
}
