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
    /// Set when the sync stopped because the device is short of space; says so in words.
    private(set) var storageNotice: String?
    private(set) var isActive = false
    /// True while the index is made again because the mail folder changed in Files.
    private(set) var isCheckingFolder = false
    /// Why iOS refused to schedule the background check, in words; nil when it accepted it.
    var backgroundNotice: String?
    /// The most recent background run, if any.
    private(set) var lastBackgroundRun: BackgroundRun?

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let freeSpace: @Sendable (URL) -> Int64?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var leaving: Task<Void, Never>?
    @ObservationIgnored private var spaceWatch: Task<Void, Never>?
    /// How long to wait for a submission in flight before letting iOS suspend the app anyway;
    /// the outbox journal keeps a cut-off send at most once.
    @ObservationIgnored var sendGrace: Duration = .seconds(25)
    @ObservationIgnored var clock: () -> Date = Date.init

    init(model: AppModel, defaults: UserDefaults = .standard,
         freeSpace: @escaping @Sendable (URL) -> Int64? = FreeSpace.available) {
        self.model = model
        self.defaults = defaults
        self.freeSpace = freeSpace
        self.budget = StorageBudget.load(from: defaults)
        if let data = defaults.data(forKey: Self.lastRunKey) {
            lastBackgroundRun = try? JSONDecoder().decode(BackgroundRun.self, from: data)
        }
        model.sync.services.syncOptions = budget.syncOptions
    }

    /// The app's model: the Keychain, the standard folders, in-process attachment text with
    /// its crash records (MAIL-052), system notifications.
    static func live() -> MobileSession {
        let defaults = UserDefaults.standard
        var services = AccountServices.live
        services.syncOptions = StorageBudget.load(from: defaults).syncOptions
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
        if hasRoom(store) {
            await model.sync.start(model.accounts, store: store)
            await model.registerForSending(model.accounts)
            model.indexAttachmentTextInBackground()
        }
        DeviceCache.trim(deviceFolder: store.locations.deviceFolder, to: budget.cacheBytes)
        watchFreeSpace()
    }

    /// The app left the screen: stop the sync and IDLE (iOS closes sockets soon anyway), let a
    /// submission in flight finish under a background task, trim the cache.
    func enteredBackground(_ runner: any BackgroundTaskRunning) async {
        isActive = false
        spaceWatch?.cancel()
        spaceWatch = nil
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
            if let folder = self.model.mailStore?.locations.deviceFolder {
                DeviceCache.trim(deviceFolder: folder, to: self.budget.cacheBytes)
            }
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
        if hasRoom(store) {
            await model.sync.start(model.accounts, store: store)
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
                guard model.sync.isSyncing(account.id) else { return false }
                guard let progress = model.sync.progress[account.id] else { return true }
                switch progress.activity {
                case .signInFailed, .waitingToRetry, .stopped: return false
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
        guard isActive, let store = model.mailStore else { return }
        // Running syncs keep the options they started with: start them again.
        await model.sync.stopAll()
        if hasRoom(store) {
            await model.sync.start(model.accounts, store: store)
            await model.registerForSending(model.accounts)
        }
        DeviceCache.trim(deviceFolder: store.locations.deviceFolder, to: budget.cacheBytes)
    }

    /// False, with the notice set, when free space is under the budget's minimum.
    private func hasRoom(_ store: MailStore) -> Bool {
        guard let free = freeSpace(store.locations.mailFolder) else { storageNotice = nil; return true }
        if free < budget.minimumFreeBytes {
            let limit = ByteCountFormatter.string(fromByteCount: budget.minimumFreeBytes, countStyle: .memory)
            storageNotice = "Mail stopped downloading: less than \(limit) is free on \(DeviceWords.this). It carries on when there is room."
            return false
        }
        storageNotice = nil
        return true
    }

    /// While active, looks at free space every minute: stops the sync under the minimum and
    /// starts it again when there is room.
    private func watchFreeSpace() {
        spaceWatch?.cancel()
        spaceWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.isActive, let store = self.model.mailStore else { return }
                let wasPaused = self.storageNotice != nil
                if !self.hasRoom(store) {
                    if !wasPaused { await self.model.sync.stopAll() }
                } else if wasPaused {
                    await self.model.sync.start(self.model.accounts, store: store)
                }
            }
        }
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
