import Foundation
import MailClassifier
import MailCore
import MailStore

/// Which new mail may notify (GKM-018; Classification.md, Notifications). Per account, per
/// mailing list within an account, and per space (GKM-037, MAIL-085). Kept on this device in
/// `preferences/notifications.json` beside the remote-image choices (MAIL-033); GKM-026 moves
/// both to private CloudKit.
struct NotificationSettings: Codable, Equatable {
    enum AccountLevel: String, Codable, CaseIterable, Identifiable {
        /// New mail in Focused notifies and counts on the badge (the default).
        case focused
        /// Nothing from this account notifies or counts on the badge. It is still all there.
        case off
        var id: String { rawValue }
    }

    enum ListLevel: String, Codable, CaseIterable, Identifiable {
        /// Like the rest of the account: only when the message is in Focused.
        case automatic
        /// Every new message on the list notifies, wherever it lives (never from Quarantine).
        case always
        /// The list never notifies.
        case muted
        var id: String { rawValue }
    }

    /// A space has the same three choices as a list: like the rest of Focused, Always (never
    /// from Quarantine) or Never.
    typealias SpaceLevel = ListLevel

    struct ListKey: Codable, Hashable {
        var account: MailAccountID
        /// The List-ID, as the store keeps it (lowercased, no angle brackets).
        var list: String
    }

    var accounts: [MailAccountID: AccountLevel] = [:]
    var lists: [ListKey: ListLevel] = [:]
    /// Spaces span accounts, so their choice does too. A deleted space's choice is kept, which
    /// is harmless and brings it back with the space (a space file can be briefly unreadable
    /// while another device writes it).
    var spaces: [MailSpaceID: SpaceLevel] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case accounts, lists, spaces }

    /// A file from before spaces had a choice (GKM-018) has no `spaces`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([MailAccountID: AccountLevel].self, forKey: .accounts) ?? [:]
        lists = try container.decodeIfPresent([ListKey: ListLevel].self, forKey: .lists) ?? [:]
        spaces = try container.decodeIfPresent([MailSpaceID: SpaceLevel].self, forKey: .spaces) ?? [:]
    }

    func level(_ account: MailAccountID) -> AccountLevel { accounts[account] ?? .focused }

    func level(list: String?, account: MailAccountID) -> ListLevel {
        guard let list else { return .automatic }
        return lists[ListKey(account: account, list: list)] ?? .automatic
    }

    func level(space: MailSpaceID) -> SpaceLevel { spaces[space] ?? .automatic }

    /// Lists with a choice of their own, for the settings sheet.
    var customLists: [(key: ListKey, level: ListLevel)] {
        lists.filter { $0.value != .automatic }.sorted { ($0.key.account.rawValue, $0.key.list) < ($1.key.account.rawValue, $1.key.list) }
            .map { ($0.key, $0.value) }
    }

    /// Whether a message that just arrived may notify. Uncertain mail lives in Focused, so it
    /// notifies like the rest of Focused; promotions, newsletters and routine updates are silent.
    ///
    /// Its list and every space it is in each have a say (MAIL-085): Never anywhere wins, then
    /// Always anywhere, else where it lives decides. An account that is off, Quarantine and a
    /// sender rule that silences it are never overruled.
    func notifies(_ arrival: MailArrival) -> Bool {
        // Muted and silently archived by your sender rule (GKM-019): never, whatever else says so.
        guard arrival.isUnread, arrival.home != .quarantine, !arrival.isSilenced, level(arrival.account) == .focused else { return false }
        let levels = [level(list: arrival.listID, account: arrival.account)] + arrival.spaces.map { level(space: $0) }
        if levels.contains(.muted) { return false }
        if levels.contains(.always) { return true }
        return arrival.home.asksForAttention
    }

    static func url(deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("preferences", isDirectory: true).appendingPathComponent("notifications.json")
    }

    static func load(deviceFolder: URL) throws -> NotificationSettings {
        let url = url(deviceFolder: deviceFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return NotificationSettings() }
        return try JSONDecoder().decode(NotificationSettings.self, from: Data(contentsOf: url))
    }

    func save(deviceFolder: URL) throws {
        let url = Self.url(deviceFolder: deviceFolder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// One notification to post.
struct MailNotification: Equatable, Sendable {
    /// The message it opens, or nil for a summary of several.
    var message: MailMessageID?
    var title: String
    var body: String
}

/// What the system allows.
enum NotificationPermission: Equatable, Sendable {
    case notAsked, allowed, denied
}

/// Posts notifications. The app's is `UserNotificationPoster` (UserNotifications); the tests
/// record what would be posted, since there is no notification centre without an app bundle.
protocol MailNotificationPosting: Sendable {
    func permission() async -> NotificationPermission
    /// Asks the system once; returns what it answered.
    func requestPermission() async throws -> NotificationPermission
    func post(_ notification: MailNotification) async throws
}

extension MailNotification {
    /// At most this many separate notifications at once; more become one summary.
    static let separateLimit = 3
    /// Mail older than this when it arrives is history being downloaded, not new mail.
    static let newMailWindow: TimeInterval = 24 * 3600

    /// The notifications for a batch of arrivals.
    static func make(for arrivals: [MailArrival], settings: NotificationSettings, now: Date) -> [MailNotification] {
        let eligible = arrivals.filter { settings.notifies($0) && now.timeIntervalSince($0.received) < newMailWindow }
        guard eligible.count <= separateLimit else {
            return [MailNotification(message: nil, title: "GitKittie Mail", body: "\(eligible.count) new messages")]
        }
        return eligible.map { arrival in
            let sender = arrival.fromName?.isEmpty == false ? arrival.fromName! : (arrival.fromAddress ?? "Unknown sender")
            let subject = arrival.subject?.isEmpty == false ? arrival.subject! : "(No subject)"
            return MailNotification(message: arrival.id, title: sender, body: subject)
        }
    }
}
