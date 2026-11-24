import Foundation
import MailClassifier
import MailCore
import MailStore
import Observation

/// What deserves attention (GKM-018): the category counts the sidebar shows, the badge, the
/// background classification of mail stored before (GKM-017), and quiet notifications.
///
/// Unread and attention are different numbers: every view shows its unread count, but only
/// unread mail in Focused counts on the badge and may notify. Promotions, newsletters and
/// routine updates never do, unless you choose that for a list.
@MainActor
@Observable
final class MailAttention {
    /// Per category view, across accounts.
    private(set) var counts: [MailCategory: CategoryCount] = [:]
    /// Unread mail in Focused, from accounts whose notifications are on: the Dock badge.
    private(set) var badgeCount = 0
    /// Messages still waiting for a verdict (after an upgrade or a rebuild).
    private(set) var pendingClassification = 0
    private(set) var settings = NotificationSettings()
    private(set) var permission = NotificationPermission.notAsked
    /// Why classification or notifications failed last, for a notice.
    private(set) var lastError: String?

    @ObservationIgnored private var store: MailStore?
    @ObservationIgnored private var deviceFolder: URL?
    @ObservationIgnored private let poster: (any MailNotificationPosting)?
    /// Arrivals up to here have been considered for notifications.
    @ObservationIgnored private var cursor: Int64 = 0
    @ObservationIgnored private var classification: Task<Void, Never>?
    /// Injected for tests.
    @ObservationIgnored var now: () -> Date = Date.init

    init(poster: (any MailNotificationPosting)?) {
        self.poster = poster
    }

    /// A newly opened store: its settings, and notifications start after what is already there.
    func attach(_ store: MailStore) async throws {
        self.store = store
        deviceFolder = store.locations.deviceFolder
        settings = try NotificationSettings.load(deviceFolder: store.locations.deviceFolder)
        cursor = try await store.latestArrival()
        if let poster { permission = await poster.permission() }
    }

    func count(_ category: MailCategory) -> CategoryCount { counts[category] ?? CategoryCount() }

    // MARK: Refresh

    /// What to do with mail that arrived since the last refresh.
    enum Arrivals {
        /// Post notifications for it (synced mail).
        case notify
        /// Mark it seen without notifying (imported mail).
        case skip
        /// Leave it for the next refresh (only the counts changed).
        case leave
    }

    /// Re-reads the counts and handles mail that arrived since.
    func refresh(accounts: [MailAccount], arrivals: Arrivals) async {
        guard let store else { return }
        do {
            counts = try await store.categoryCounts()
            var badge = count(.focused).unread
            for account in accounts where settings.level(account.id) == .off {
                badge -= try await store.categoryCounts(account: account.id)[.focused]?.unread ?? 0
            }
            badgeCount = max(0, badge)
            pendingClassification = try await store.pendingClassificationCount()
            if let error = await store.lastClassificationError { lastError = "Some mail couldn’t be sorted yet: \(error)" }
            if arrivals != .leave { try await considerArrivals(store, notify: arrivals == .notify) }
        } catch {
            lastError = String(describing: error)
        }
    }

    private func considerArrivals(_ store: MailStore, notify: Bool) async throws {
        while true {
            let arrivals = try await store.arrivals(after: cursor, limit: 200)
            guard let last = arrivals.last else { return }
            cursor = last.sequence
            guard notify, let poster else { continue }
            let notifications = MailNotification.make(for: arrivals, settings: settings, now: now())
            guard !notifications.isEmpty else { continue }
            if permission == .notAsked { permission = try await poster.requestPermission() }
            guard permission == .allowed else { continue }
            for notification in notifications { try await poster.post(notification) }
        }
    }

    // MARK: Background classification

    /// Classifies mail that has no verdict yet, a batch at a time, refreshing the counts as it
    /// goes; `didFinish` runs once at the end (the list reloads). Mail waiting for its verdict
    /// shows in Focused meanwhile.
    func classifyInBackground(didFinish: @escaping @MainActor () async -> Void) {
        guard classification == nil, let store else { return }
        classification = Task { [weak self] in
            var classifiedAny = false
            while !Task.isCancelled {
                do {
                    let done = try await store.classifyPending(limit: 100)
                    guard done > 0 else { break }
                    classifiedAny = true
                    self?.pendingClassification = try await store.pendingClassificationCount()
                    self?.counts = try await store.categoryCounts()
                } catch {
                    self?.lastError = "Some mail couldn’t be sorted yet: \(error)"
                    break
                }
            }
            self?.classification = nil
            if classifiedAny { await didFinish() }
        }
    }

    /// Waits for the background classification, for tests.
    func waitForClassification() async { await classification?.value }

    // MARK: Settings

    func setLevel(_ level: NotificationSettings.AccountLevel, for account: MailAccountID, accounts: [MailAccount]) async {
        settings.accounts[account] = level == .focused ? nil : level
        await saveSettings(accounts: accounts)
    }

    func setLevel(_ level: NotificationSettings.ListLevel, list: String, account: MailAccountID, accounts: [MailAccount]) async {
        settings.lists[NotificationSettings.ListKey(account: account, list: list)] = level == .automatic ? nil : level
        await saveSettings(accounts: accounts)
    }

    private func saveSettings(accounts: [MailAccount]) async {
        guard let deviceFolder else { return }
        do {
            try settings.save(deviceFolder: deviceFolder)
        } catch {
            lastError = String(describing: error)
        }
        await refresh(accounts: accounts, arrivals: .leave)
    }

    func clearError() { lastError = nil }
}
