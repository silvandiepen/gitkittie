import Foundation
import GitKittieKit
import UserNotifications

// Notifications: a review request that newly needs an answer, and (when asked for) cards
// that are new or moved on a board. The app has no server that pushes to the phone, so it
// notices these itself: when it is open, on its regular checks, and on iOS whenever the
// system grants a background refresh. What it found before is remembered, so each thing
// is announced once.

enum NotificationCategory {
    static let reviews = "gitkanban.reviews"
    static let board = "gitkanban.board"
}

/// Receives taps on notifications and shows banners while the app is in front.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    let onOpenReviews: @MainActor () -> Void
    init(onOpenReviews: @escaping @MainActor () -> Void) { self.onOpenReviews = onOpenReviews }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.categoryIdentifier == NotificationCategory.reviews {
            await onOpenReviews()
        }
    }
}

extension AppModel {
    private static let reviewsKey = "gitkanban.notify.reviews"
    private static let boardsKey = "gitkanban.notify.boards"
    private static let badgeKey = "gitkanban.notify.badge"
    private static let knownReviewsKey = "gitkanban.notify.knownReviews"
    private static let announcedChangesKey = "gitkanban.notify.announcedChanges"

    private func setting(_ key: String, default fallback: Bool) -> Bool {
        _ = notificationSettingsVersion
        return (defaults.object(forKey: key) as? Bool) ?? fallback
    }

    private func set(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
        notificationSettingsVersion += 1
    }

    /// Tell me when a review request needs an answer.
    public var notifiesReviews: Bool {
        get { setting(Self.reviewsKey, default: true) }
        set { set(Self.reviewsKey, newValue) }
    }

    /// Tell me when cards are new or moved on a board.
    public var notifiesBoardChanges: Bool {
        get { setting(Self.boardsKey, default: false) }
        set { set(Self.boardsKey, newValue) }
    }

    /// Show the number of items waiting for review on the app's icon.
    public var badgesReviews: Bool {
        get { setting(Self.badgeKey, default: true) }
        set { set(Self.badgeKey, newValue); Task { await updateBadge() } }
    }

    /// Whether anything is switched on that needs the app to keep checking.
    public var wantsBackgroundChecks: Bool { notificationRouter != nil && (notifiesReviews || notifiesBoardChanges || badgesReviews) }

    /// Called once by the app at launch: from here on notifications can be posted and
    /// their taps are handled.
    public func startNotifications() async {
        guard notificationRouter == nil else { return }
        let router = NotificationRouter { [weak self] in self?.wantsReviews = true }
        notificationRouter = router
        UNUserNotificationCenter.current().delegate = router
        await refreshNotificationPermission()
    }

    public func refreshNotificationPermission() async {
        guard notificationRouter != nil else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: notificationsAllowed = nil
        case .denied: notificationsAllowed = false
        default: notificationsAllowed = true
        }
    }

    /// Ask the system for permission (it asks the user once; after a "no" only the
    /// system's settings can change it).
    @discardableResult
    public func requestNotificationPermission() async -> Bool {
        guard notificationRouter != nil else { return false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshNotificationPermission()
        if granted { await updateBadge() }
        return granted
    }

    private func post(title: String, body: String, category: String, id: String) async {
        guard notificationRouter != nil, notificationsAllowed == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = category
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func updateBadge() async {
        guard notificationRouter != nil, notificationsAllowed == true else { return }
        try? await UNUserNotificationCenter.current().setBadgeCount(badgesReviews ? pendingReviewTotal : 0)
    }

    /// Which of the open requests have not been announced yet, given what was known.
    /// `known == nil` is the very first look: everything there is the starting point.
    static func newlyOpen(_ open: [String], known: [String]?) -> [String] {
        guard let known else { return [] }
        let seen = Set(known)
        return open.filter { !seen.contains($0) }
    }

    /// The inbox was loaded: announce requests that newly need an answer.
    func reviewInboxDidLoad() async {
        let open = openReviewRequests
        let ids = open.map { $0.ref.id }
        let fresh = Set(Self.newlyOpen(ids, known: defaults.stringArray(forKey: Self.knownReviewsKey)))
        defaults.set(ids, forKey: Self.knownReviewsKey)
        guard notificationRouter != nil else { return }
        // The first requests found are the moment to ask: there is something to be told about.
        if notificationsAllowed == nil, notifiesReviews, !open.isEmpty { await requestNotificationPermission() }
        await updateBadge()
        guard notifiesReviews, !fresh.isEmpty else { return }
        let requests = open.filter { fresh.contains($0.ref.id) }
        func board(_ request: ReviewRequest) -> String {
            reviewInbox.first { $0.repoID == request.origin && $0.requests.contains { $0.folder == request.folder } }?.boardName ?? "Review"
        }
        if requests.count <= 3 {
            for request in requests {
                let waiting = request.summary.pending
                await post(title: "\(board(request)): \(request.title)",
                           body: request.question ?? "\(waiting) item\(waiting == 1 ? "" : "s") to review",
                           category: NotificationCategory.reviews, id: "review|\(request.ref.id)")
            }
        } else {
            let boards = Set(requests.map(board)).sorted().joined(separator: ", ")
            await post(title: "\(requests.count) new review requests", body: boards,
                       category: NotificationCategory.reviews, id: "reviews|\(Date().timeIntervalSince1970)")
        }
    }

    /// Board summaries were refreshed: announce boards with more new or moved cards than
    /// was last announced. Opening a board resets its count, and with it what was announced.
    func boardSummariesDidRefresh() async {
        var announced = (defaults.dictionary(forKey: Self.announcedChangesKey) as? [String: Int]) ?? [:]
        let firstLook = defaults.object(forKey: Self.announcedChangesKey) == nil
        for repo in addedRepos {
            for board in repo.boards {
                let key = "\(repo.id)|\(board.folder)"
                guard let changed = boardSummaries[key]?.changed else { continue }
                let before = announced[key] ?? 0
                announced[key] = changed
                if !firstLook, notifiesBoardChanges, changed > before {
                    await post(title: board.name, body: "\(changed) task\(changed == 1 ? " is" : "s are") new or moved since you last looked",
                               category: NotificationCategory.board, id: "board|\(key)")
                }
            }
        }
        defaults.set(announced, forKey: Self.announcedChangesKey)
    }

    /// One round of looking for news, for the app's regular checks and background refresh.
    public func checkForNews() async {
        if addedRepos.isEmpty { await restoreForSharing() }
        if notifiesBoardChanges { await refreshBoardSummaries() }
        await loadReviewInbox()
    }
}
