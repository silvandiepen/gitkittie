import Foundation
import GitKittieKit
import UserNotifications

// Notifications: a review request that newly needs an answer, and (when asked for) cards
// that are new or moved on a board. Review requests on a repo with instant notifications
// arrive as pushes from the relay (AppModel+Push.swift). The app also notices them itself,
// as the fallback: when it is open, on its regular checks, and on iOS whenever the system
// grants a background refresh. What it found before, and what a push already announced, is
// remembered, so each thing is announced once. A request's `notify:` sets how loudly:
// urgent is time-sensitive, silent only counts on the badge.

enum NotificationCategory {
    static let reviews = "gitkanban.reviews"
    static let board = "gitkanban.board"
    static let newBoard = "gitkanban.newBoard"
}

/// Receives taps on notifications and shows banners while the app is in front.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// A notification about reviews was tapped; with the request it names, when it names one.
    let onOpenReviews: @MainActor (PushedReview?) -> Void
    /// A push about a request is being shown while the app is in front.
    let onPushShown: @MainActor (PushedReview) -> Void

    init(onOpenReviews: @escaping @MainActor (PushedReview?) -> Void, onPushShown: @escaping @MainActor (PushedReview) -> Void) {
        self.onOpenReviews = onOpenReviews
        self.onPushShown = onPushShown
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.trigger is UNPushNotificationTrigger,
           let review = PushedReview(userInfo: notification.request.content.userInfo) {
            await onPushShown(review)
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if let review = PushedReview(userInfo: content.userInfo) {
            await onOpenReviews(review)
        } else if content.categoryIdentifier == NotificationCategory.reviews {
            await onOpenReviews(nil)
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

    /// Tell me when a review request needs an answer. Off also stops instant notifications.
    public var notifiesReviews: Bool {
        get { setting(Self.reviewsKey, default: true) }
        set { set(Self.reviewsKey, newValue); Task { await reviewNotificationsDidChange() } }
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
        let router = NotificationRouter(
            onOpenReviews: { [weak self] review in
                guard let self else { return }
                if let review { Task { await self.openPushedReview(review) } } else { self.wantsReviews = true }
            },
            onPushShown: { [weak self] review in
                self?.notePushAnnounced(review)
                Task { await self?.checkForNews() }
            })
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
        if granted { await updateBadge(); await registerForReviewPushes() }
        return granted
    }

    private func post(title: String, body: String, category: String, id: String,
                      level: ReviewNotify = .normal, userInfo: [AnyHashable: Any] = [:]) async {
        guard notificationRouter != nil, notificationsAllowed == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = category
        content.userInfo = userInfo
        // Urgent breaks through Focus (the Time Sensitive Notifications entitlement).
        content.interruptionLevel = level == .urgent ? .timeSensitive : .active
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

    /// What a request asks of the reviewer, for a notification: "3 items to review",
    /// "2 questions to answer", "1 item and 1 question waiting".
    nonisolated static func waitingLine(_ summary: ReviewSummary) -> String {
        let items = summary.pendingItems, questions = summary.unanswered, checks = summary.pendingChecks
        if questions == 0, checks == 0 { return "\(items) item\(items == 1 ? "" : "s") to review" }
        if items == 0, checks == 0 { return "\(questions) question\(questions == 1 ? "" : "s") to answer" }
        if items == 0, questions == 0 { return "\(checks) page\(checks == 1 ? "" : "s") to check" }
        return "\(summary.waitingDescription) waiting"
    }

    /// Which newly open requests the app should announce itself: not silent ones, not ones
    /// below the level asked for, and not ones a push (`pushed`, notification ids) or an
    /// earlier notification still on screen (`delivered`) already told about.
    static func toAnnounce(_ requests: [ReviewRequest], pushed: Set<String>, delivered: Set<String>,
                           announces: (ReviewNotify) -> Bool) -> [ReviewRequest] {
        requests.filter { request in
            let id = reviewNotificationID(repo: request.origin, folder: request.folder)
            return announces(request.notify) && !pushed.contains(id) && !delivered.contains(id)
        }
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
        let delivered = Set(await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier))
        let requests = Self.toAnnounce(open.filter { fresh.contains($0.ref.id) }, pushed: Set(pushAnnounced),
                                       delivered: delivered, announces: announces)
        guard !requests.isEmpty else { return }
        func board(_ request: ReviewRequest) -> String {
            reviewInbox.first { $0.repoID == request.origin && $0.requests.contains { $0.folder == request.folder } }?.boardName ?? "Review"
        }
        if requests.count <= 3 {
            for request in requests {
                // The same id as the relay's push for it, and what a tap needs to open it.
                let pushed = PushedReview(repo: request.origin, folder: request.folder, id: request.id,
                                          board: board(request), level: request.notify)
                await post(title: "\(board(request)): \(request.title)",
                           body: request.question ?? Self.waitingLine(request.summary),
                           category: NotificationCategory.reviews,
                           id: reviewNotificationID(repo: request.origin, folder: request.folder),
                           level: request.notify, userInfo: pushed.userInfo)
            }
        } else {
            let boards = Set(requests.map(board)).sorted().joined(separator: ", ")
            await post(title: "\(requests.count) new review requests", body: boards,
                       category: NotificationCategory.reviews, id: "reviews|\(Date().timeIntervalSince1970)",
                       level: requests.contains { $0.notify == .urgent } ? .urgent : .normal)
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
        await refreshBoardSuggestions()
    }

    /// A new board in a repository that is already added: opening the app asks whether to add it.
    func postNewBoard(_ suggestion: BoardSuggestion) async {
        await post(title: "New board: \(suggestion.name)",
                   body: "\(suggestion.repoName) has a new board. Open Tasks to add it.",
                   category: NotificationCategory.newBoard, id: "newBoard.\(suggestion.id)")
    }
}
