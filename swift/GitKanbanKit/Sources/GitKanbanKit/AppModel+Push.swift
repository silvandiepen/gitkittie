import Foundation
import GitKittieKit

// Instant review notifications: the device's push token, registering it with the relay for
// every added repo, and what a push does when it arrives or is tapped. See ReviewPush.swift
// for the relay calls and apps/gitkanban-relay/docs/Push.md for the whole picture.
//
// The app's own checks (AppModel+Notifications.swift) keep running as the fallback; a
// request a push already announced is not announced again by them.

/// Whether a repo's review requests reach this device the moment they are asked.
public enum InstantNotificationState: Equatable, Sendable {
    case on
    /// GitHub: the GitKittie Tasks app is not installed on the repo; this page installs it.
    case needsInstall(URL)
    /// GitLab: the repo has no relay channel yet (Tasks adds the webhook when turned on).
    case needsChannel
    /// It cannot be turned on, in words.
    case unavailable(String)
}

extension AppModel {
    private static let deviceTokenKey = "gitkanban.push.deviceToken"
    private static let environmentKey = "gitkanban.push.environment"
    private static let githubReposKey = "gitkanban.push.githubRepos"
    private static let channelsKey = "gitkanban.push.channels"
    private static let pushedKey = "gitkanban.push.announced"
    private static let urgentOnlyKey = "gitkanban.notify.urgentOnly"

    /// Notify only about requests marked `notify: urgent`; others still count on the badge.
    public var notifiesUrgentReviewsOnly: Bool {
        get { _ = notificationSettingsVersion; return defaults.bool(forKey: Self.urgentOnlyKey) }
        set {
            defaults.set(newValue, forKey: Self.urgentOnlyKey)
            notificationSettingsVersion += 1
            Task { await registerForReviewPushes() }
        }
    }

    /// The levels this device wants an alert for. Silent ones always come, to keep the badge right.
    var wantedLevels: [ReviewNotify] { notifiesUrgentReviewsOnly ? [.urgent, .silent] : ReviewNotify.allCases }

    /// Whether a request at `level` should be announced with a banner here.
    func announces(_ level: ReviewNotify) -> Bool { Self.announces(level, urgentOnly: notifiesUrgentReviewsOnly) }

    nonisolated static func announces(_ level: ReviewNotify, urgentOnly: Bool) -> Bool {
        level != .silent && (!urgentOnly || level == .urgent)
    }

    /// The app got its push token from the system (at every launch). `sandbox` for builds
    /// signed for development, `production` otherwise.
    public func didRegisterForRemoteNotifications(deviceToken: Data, environment: String) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let previous = defaults.string(forKey: Self.deviceTokenKey)
        if let previous, previous != token { await unregisterFromReviewPushes() }
        defaults.set(token, forKey: Self.deviceTokenKey)
        defaults.set(environment, forKey: Self.environmentKey)
        await registerForReviewPushes()
    }

    private var pushDevice: PushDevice? {
        guard let token = defaults.string(forKey: Self.deviceTokenKey) else { return nil }
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        return PushDevice(token: token, platform: platform,
                          environment: defaults.string(forKey: Self.environmentKey) ?? "production",
                          levels: wantedLevels.map(\.rawValue),
                          appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }

    private var registeredGitHubRepos: [String: Int] {
        get { (defaults.dictionary(forKey: Self.githubReposKey) as? [String: Int]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.githubReposKey) }
    }

    private var registeredChannels: [String: RelayConfig] {
        get {
            guard let data = defaults.data(forKey: Self.channelsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: RelayConfig].self, from: data)) ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.channelsKey) }
    }

    /// Register this device with the relay for every added provider repo, and note per repo
    /// what is still needed. Does nothing while review notifications are off or not allowed.
    /// Running it again renews each registration (the relay drops ones not renewed for weeks).
    public func registerForReviewPushes() async {
        guard notificationRouter != nil, notifiesReviews, notificationsAllowed == true,
              let device = pushDevice, let connection else { return }
        let clientID = RelayClientProof.clientID(in: defaults)
        var states: [String: InstantNotificationState] = [:]
        for repo in addedRepos where !repo.kind.isFolder {
            if connection.choice == .github {
                guard let relay = URL(string: relayURL), relay.scheme?.hasPrefix("http") == true else {
                    states[repo.id] = .unavailable("The relay's address is not valid.")
                    continue
                }
                do {
                    switch try await PushRelay.registerGitHub(relay: relay, repo: repo.fullName, userToken: connection.token,
                                                              device: device, clientID: clientID) {
                    case .registered(let repoID):
                        registeredGitHubRepos[repo.id] = repoID
                        states[repo.id] = .on
                    case .notInstalled(let url):
                        states[repo.id] = .needsInstall(url)
                    case .refused(let reason):
                        states[repo.id] = .unavailable(reason)
                    }
                } catch {
                    states[repo.id] = .unavailable(error.localizedDescription)
                }
            } else {
                guard let source = source(for: repo),
                      let text = try? await source.readText(RelayConfig.path),
                      let config = try? JSONDecoder().decode(RelayConfig.self, from: Data(text.utf8)) else {
                    states[repo.id] = .needsChannel
                    continue
                }
                do {
                    try await PushRelay.registerChannel(config, device: device, clientID: clientID)
                    registeredChannels[repo.id] = config
                    states[repo.id] = .on
                } catch {
                    states[repo.id] = .unavailable(error.localizedDescription)
                }
            }
        }
        instantNotifications = states
    }

    /// Tell the relay to stop sending to this device (review notifications were turned off).
    public func unregisterFromReviewPushes() async {
        guard let token = defaults.string(forKey: Self.deviceTokenKey) else { return }
        if let relay = URL(string: relayURL) {
            for repoID in registeredGitHubRepos.values { await PushRelay.unregisterGitHub(relay: relay, repoID: repoID, token: token) }
        }
        for config in registeredChannels.values { await PushRelay.unregisterChannel(config, token: token) }
        registeredGitHubRepos = [:]
        registeredChannels = [:]
        instantNotifications = [:]
    }

    /// The review notifications switch changed.
    func reviewNotificationsDidChange() async {
        if notifiesReviews { await registerForReviewPushes() } else { await unregisterFromReviewPushes() }
    }

    /// Turn on instant notifications for a GitLab repo: add its relay channel (Tasks creates
    /// the webhook with the signed-in account), then register. A GitHub repo is turned on by
    /// installing the GitKittie Tasks app on the page in `.needsInstall`, then
    /// `registerForReviewPushes()`.
    public func turnOnInstantNotifications(for repoID: String) async {
        guard let repo = addedRepos.first(where: { $0.id == repoID }), instantNotifications[repoID] == .needsChannel else { return }
        if await enableLiveUpdates(on: repo) {
            if repo.id == activeRepo?.id { startWatching() }
            await registerForReviewPushes()
        }
    }

    /// A link that opened the app: GitHub's page after installing GitKittie Tasks
    /// (`gitkittie-tasks://github-installed`), or a new task from another app.
    public func openURL(_ url: URL) {
        if url.scheme == "gitkittie-tasks", url.host == "github-installed" {
            Task { await registerForReviewPushes() }
        } else {
            openTaskRequest(url)
        }
    }

    // MARK: Pushes that arrive

    /// Notification ids of requests a push already announced, newest last.
    var pushAnnounced: [String] { defaults.stringArray(forKey: Self.pushedKey) ?? [] }

    func notePushAnnounced(_ review: PushedReview) {
        let id = reviewNotificationID(repo: review.repo, folder: review.folder)
        var ids = pushAnnounced.filter { $0 != id }
        ids.append(id)
        defaults.set(Array(ids.suffix(200)), forKey: Self.pushedKey)
    }

    /// A push reached the app (in the background, or shown while it is open). It notes what
    /// was announced, then looks: the inbox and the badge catch up, and nothing is told twice.
    public func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        if let review = PushedReview(userInfo: userInfo) { notePushAnnounced(review) }
        await checkForNews()
    }

    /// A notification about one request was tapped: open that request.
    func openPushedReview(_ review: PushedReview) async {
        notePushAnnounced(review)
        if reviewInbox.flatMap(\.requests).first(where: { $0.ref == review.ref }) == nil { await loadReviewInbox() }
        reviewsFocusRequest = review.ref
        wantsReviews = true
    }
}
