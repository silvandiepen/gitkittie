import Foundation
import MailCore
import MailExtraction
import MailStore
import MailSync
import Observation

/// Keeps a short piece of work running after the app leaves the screen, for as long as iOS
/// allows. The app's is `UIApplication.beginBackgroundTask`; tests run the work directly.
@MainActor
protocol BackgroundTaskRunning {
    func begin(_ name: String, expiration: @escaping @MainActor () -> Void) -> Int
    func end(_ id: Int)
}

/// Set when iOS takes the background time back.
@MainActor
private final class Expiry {
    var passed = false
}

/// What the last background run did, for Settings ▸ Background.
struct BackgroundRun: Codable, Equatable {
    enum Kind: String, Codable { case refresh, processing }
    var kind: Kind
    var started: Date
    var finished: Date
    var imported: Int
    /// The run ended because iOS took the time back before every account finished a pass.
    var cutShort: Bool
}

/// The iPhone and iPad app around the shared `AppModel` (MAIL-053): sync and IMAP IDLE only
/// while the app is active; on leaving the screen the sync stops and an SMTP submission in
/// flight finishes under a background task; `BGAppRefreshTask` checks for new mail and
/// `BGProcessingTask` catches up; storage stays within the budget (MAIL-051). UI-free: the
/// scene phase and the background task handlers call these intents.
@MainActor
@Observable
final class MobileSession {
    let model: AppModel
    private(set) var budget: StorageBudget
    /// Set while downloading is paused because the device is short of space; says so in words.
    /// The pause itself is the shared sync's (`AccountSync.downloadPause`, MAIL-106), the Mac's too.
    var storageNotice: String? { model.sync.downloadPause?.text }
    private(set) var isActive = false
    /// True while the index is made again because the mail folder changed in Files.
    private(set) var isCheckingFolder = false
    /// Why iOS refused to schedule the background check, in words; nil when it accepted it.
    var backgroundNotice: String?
    /// The most recent background run, if any.
    private(set) var lastBackgroundRun: BackgroundRun?

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var leaving: Task<Void, Never>?
    /// How long to wait for a submission in flight before letting iOS suspend the app anyway;
    /// the outbox journal keeps a cut-off send at most once.
    @ObservationIgnored var sendGrace: Duration = .seconds(25)
    @ObservationIgnored var clock: () -> Date = Date.init

    init(model: AppModel, defaults: UserDefaults = .standard,
         freeSpace: @escaping @Sendable (URL) -> Int64? = FreeSpace.available) {
        self.model = model
        self.defaults = defaults
        self.budget = StorageBudget.load(from: defaults)
        if let data = defaults.data(forKey: Self.lastRunKey) {
            lastBackgroundRun = try? JSONDecoder().decode(BackgroundRun.self, from: data)
        }
        model.sync.services.syncOptions = budget.syncOptions
        model.sync.services.offlineCacheBytes = budget.cacheBytes
        model.sync.services.freeSpace = freeSpace
        model.sync.services.minimumFreeBytes = budget.minimumFreeBytes
    }

    /// The app's model: the Keychain, the standard folders, in-process attachment text with
    /// its crash records (MAIL-052), system notifications.
    static func live() -> MobileSession {
        let defaults = UserDefaults.standard
        var services = AccountServices.live
        services.syncOptions = StorageBudget.load(from: defaults).syncOptions
        services.offlineCacheBytes = StorageBudget.load(from: defaults).cacheBytes
        let attempts = (try? StoreLocations.standard()).map {
            DeviceCache.folder(in: $0.deviceFolder).appendingPathComponent("attachment-text-attempts", isDirectory: true)
        }
        let model = AppModel(extractor: InProcessTextExtractor(attemptsFolder: attempts), services: services,
                             notifications: UserNotificationPoster())
        return MobileSession(model: model, defaults: defaults)
    }

    // MARK: Opening

    /// Opens the store once, whoever asks first: the scene or a background task.
    func ensureOpen() async {
        if model.phase == .ready { return }
        if let opening { return await opening.value }
        let task = Task { @MainActor in
            await self.model.open()
            if let folder = self.model.mailStore?.locations.deviceFolder { try? DeviceCache.prepare(deviceFolder: folder) }
        }
        opening = task
        await task.value
        opening = nil
    }

    // MARK: Foreground

    /// The app is on screen: check the folder against the index, then sync and IDLE.
    func becameActive() async {
        isActive = true
        await leaving?.value
        model.extractsAttachmentText = true
        let firstOpen = model.phase != .ready
        await ensureOpen()
        guard isActive, let store = model.mailStore else { return }
        if !firstOpen { await model.sync.stopAll() }
        await checkMailFolder(store)
        guard isActive else { return }
        // The sync looks at the free space itself: under the budget's minimum nothing downloads,
        // and it carries on by itself when there is room (MAIL-106).
        await model.sync.start(model.accounts, store: store)
        if model.sync.downloadPause == nil {
            await model.registerForSending(model.accounts)
            model.indexAttachmentTextInBackground()
        }
        await trimCache(store)
    }

    /// The app left the screen: stop the sync and IDLE (iOS closes sockets soon anyway), let a
    /// submission in flight finish under a background task, trim the cache.
    func enteredBackground(_ runner: any BackgroundTaskRunning) async {
        isActive = false
        let task = Task { @MainActor in
            let expiry = Expiry()
            let id = runner.begin("Finish sending") { expiry.passed = true }
            defer { runner.end(id) }
            self.model.pauseAttachmentText()
            await self.model.sync.stopAll()
            let deadline = ContinuousClock.now + self.sendGrace
            while !expiry.passed, ContinuousClock.now < deadline, self.isSending {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let store = self.model.mailStore { await self.trimCache(store) }
        }
        leaving = task
        await task.value
        leaving = nil
    }

    /// True while the outbox is handing a message to a server.
    var isSending: Bool {
        model.sending?.outbox.contains { $0.state == .sending } ?? false
    }

    /// Pull to refresh.
    func refreshNow() async {
        await model.sync.syncNow()
    }

    // MARK: Background (MAIL-053)

    /// `BGAppRefreshTask`: one sync pass of every account, new mail first, then the
    /// notifications for what arrived. Returns early when iOS cancels the task.
    @discardableResult
    func backgroundRefresh() async -> BackgroundRun {
        await runInBackground(.refresh, extractText: false)
    }

    /// `BGProcessingTask`: the same, plus the index check and attachment text, until done or
    /// until iOS takes the time back.
    @discardableResult
    func backgroundProcessing() async -> BackgroundRun {
        await runInBackground(.processing, extractText: true)
    }

    private func runInBackground(_ kind: BackgroundRun.Kind, extractText: Bool) async -> BackgroundRun {
        let started = clock()
        var run = BackgroundRun(kind: kind, started: started, finished: started, imported: 0, cutShort: false)
        // A background task never runs over the open app; the foreground sync already is.
        guard !isActive else { return run }
        model.extractsAttachmentText = extractText
        await ensureOpen()
        guard let store = model.mailStore, !isActive else { return run }
        if kind == .processing { await checkMailFolder(store) }
        let before = (try? await store.messageCount()) ?? 0
        await model.sync.start(model.accounts, store: store)
        if model.sync.downloadPause == nil {
            run.cutShort = !(await waitForOnePass(since: started))
            if extractText, !Task.isCancelled {
                model.indexAttachmentTextInBackground()
                await model.waitForAttachmentText()
            }
        }
        if !isActive {
            await model.sync.stopAll()
            model.pauseAttachmentText()
        }
        // Counts, the badge and the notifications for what arrived.
        await model.refreshAfterSync()
        run.imported = max(0, ((try? await store.messageCount()) ?? before) - before)
        run.finished = clock()
        record(run)
        return run
    }

    /// Waits until every syncing account finished a pass that started after `start`, gave up
    /// (password refused, offline), or the task was cancelled. True when every account finished.
    private func waitForOnePass(since start: Date) async -> Bool {
        while !Task.isCancelled {
            let waiting = model.accounts.filter { account in
                guard model.sync.isSyncing(account.id), !model.sync.isPausedForSpace(account.id) else { return false }
                guard let progress = model.sync.progress[account.id] else { return true }
                switch progress.activity {
                case .signInFailed, .waitingToRetry, .pausedForSpace, .cannotStore, .stopped: return false
                default: return (progress.lastCompletedPass ?? .distantPast) < start
                }
            }
            if waiting.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private static let lastRunKey = "lastBackgroundRun"

    private func record(_ run: BackgroundRun) {
        lastBackgroundRun = run
        if let data = try? JSONEncoder().encode(run) { defaults.set(data, forKey: Self.lastRunKey) }
    }

    // MARK: Storage (MAIL-051)

    func setBudget(_ budget: StorageBudget) async {
        guard budget != self.budget else { return }
        self.budget = budget
        budget.save(to: defaults)
        model.sync.services.syncOptions = budget.syncOptions
        model.sync.services.offlineCacheBytes = budget.cacheBytes
        model.sync.services.minimumFreeBytes = budget.minimumFreeBytes
        guard isActive, let store = model.mailStore else { return }
        // Running syncs keep the options they started with: start them again.
        await model.sync.stopAll()
        await model.sync.start(model.accounts, store: store)
        if model.sync.downloadPause == nil { await model.registerForSending(model.accounts) }
        await trimCache(store)
    }

    /// Keeps the device cache within the budget: attachments first, through the store's
    /// eviction (never a pinned part or one that cannot be fetched again, MAIL-064), then the
    /// rest of `cache/`, least recently used first, in what is left.
    func trimCache(_ store: MailStore) async {
        _ = try? await store.evictCache(toFit: budget.cacheBytes)
        let attachments = (try? await store.offlineStorage().cacheBytes) ?? 0
        DeviceCache.trim(deviceFolder: store.locations.deviceFolder, to: max(0, budget.cacheBytes - attachments))
    }

    /// Messages at the providers received before the history window and not downloaded, over
    /// every syncing account (MAIL-072).
    var olderNotDownloaded: Int {
        model.sync.progress.values.reduce(0) { $0 + $1.olderNotDownloaded }
    }

    /// Downloads the mail the history window left at the provider: the window goes, and the
    /// sync imports the older mail newest first, within the storage limit, without duplicates.
    func downloadOlderMail() async {
        var budget = self.budget
        budget.historyDays = 0
        await setBudget(budget)
    }

    // MARK: The mail folder (MAIL-051)

    /// Rebuilds the index when Files added or removed originals while the app was away.
    func checkMailFolder(_ store: MailStore) async {
        let folder = store.locations.mailFolder
        guard let indexed = try? await store.messageCount() else { return }
        let stale = await Task.detached(priority: .utility) {
            MailFolderCheck.needsRebuild(mailFolder: folder, indexedCount: indexed)
        }.value
        guard stale else { return }
        isCheckingFolder = true
        await model.rebuildIndex()
        isCheckingFolder = false
    }
}
