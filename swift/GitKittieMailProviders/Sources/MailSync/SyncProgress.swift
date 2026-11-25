import Foundation
import MailProvider
import MailStore

/// How the sync is tuned. The defaults suit a desktop on an ordinary connection.
public struct SyncOptions: Sendable {
    /// On a folder's first sync, this many of its newest messages are imported before any
    /// folder's history.
    public var recentPerFolder: Int
    /// The most history (bytes of mail) to download for the account; `nil` for no limit. New
    /// mail is always imported.
    public var historyBudgetBytes: Int64?
    /// History received more than this many days ago is not downloaded (GKM-039, MAIL-072): a
    /// folder's first sync imports only the mail the provider received within the window (IMAP
    /// `UID SEARCH SINCE`, by calendar day in UTC), and later passes import history only from
    /// within it. New mail always comes in, whatever its date. `nil` (the Mac) downloads all
    /// history, within ``historyBudgetBytes``; the window applies within that budget too.
    /// Turning the window off later imports the older mail, without duplicates.
    public var historyDays: Int?
    /// Most history messages imported per pass before new mail is checked again.
    public var historyPerPass: Int
    /// Longest a pass imports history before it lists the folders and checks for new mail
    /// again (GKM-038). A pass lists every folder (SELECT + UID SEARCH ALL), so passes cut by
    /// count alone made a large first sync list every folder again every few seconds.
    public var historySlice: Duration
    /// Attachments larger than this (encoded octets) are left at the provider and fetched when
    /// opened or pinned (GKM-036, MAIL-062); `nil` downloads every message whole. Only messages
    /// larger than this are looked at part by part, so smaller mail is fetched as before.
    public var onDemandThreshold: Int?
    /// Most partial messages a pass completes for pins (GKM-036), so a large pin never holds
    /// back new mail.
    public var pinnedPerPass: Int
    /// Delete the local copy of mail deleted at the provider ("Remove mail deleted elsewhere",
    /// MAIL-075). Off: it is kept and shown as deleted there. Pinned mail, mail in a space and
    /// mail with a change in the action journal is kept either way.
    public var removesMailDeletedElsewhere: Bool
    /// Most noticed deletions a pass checks at the provider (a search per folder whose mail is
    /// not all downloaded here) before confirming them; the rest wait for the next pass.
    public var deletionChecksPerPass: Int
    /// Download the next batch while the store writes this one (GKM-038, MAIL-066). Off only to
    /// measure what it gains.
    public var pipelineStores: Bool
    /// UIDs per summary or flag fetch.
    public var summaryBatch: Int
    /// Messages and bytes per body fetch. Each fetch is a round trip and each stored batch one
    /// flush per directory and one commit, so fewer, larger batches help most on a slow link
    /// (GKM-035); the byte limit keeps a batch's memory bounded.
    public var bodyBatchMessages: Int
    public var bodyBatchBytes: Int
    /// How long one IDLE (or poll) waits before every folder is checked again. Under the
    /// 29 minutes RFC 2177 allows, and short enough for NAT timeouts.
    public var idleTimeout: Duration
    /// While a long history import runs pass after pass, flags of stored messages are checked
    /// at most this often (and once more when the history is complete). Every pass still
    /// checks for new mail first. Checking every stored message's flags on every slice made a
    /// first sync quadratic in the mailbox size (GKM-035).
    public var flagCheckInterval: Duration
    /// Backoff between reconnects. Its `maxAttempts` is not used: the sync keeps trying at the
    /// longest delay until it is stopped.
    public var reconnect: ReconnectPolicy

    public init(recentPerFolder: Int = 200, historyBudgetBytes: Int64? = nil, historyDays: Int? = nil, historyPerPass: Int = 10_000,
                historySlice: Duration = .seconds(20), onDemandThreshold: Int? = 1_000_000, pinnedPerPass: Int = 50,
                removesMailDeletedElsewhere: Bool = false, deletionChecksPerPass: Int = 50,
                pipelineStores: Bool = true,
                summaryBatch: Int = 500, bodyBatchMessages: Int = 100, bodyBatchBytes: Int = 8 * 1024 * 1024,
                idleTimeout: Duration = .seconds(9 * 60), flagCheckInterval: Duration = .seconds(120),
                reconnect: ReconnectPolicy = ReconnectPolicy()) {
        self.recentPerFolder = recentPerFolder
        self.historyBudgetBytes = historyBudgetBytes
        self.historyDays = historyDays
        self.historyPerPass = historyPerPass
        self.historySlice = historySlice
        self.onDemandThreshold = onDemandThreshold
        self.pinnedPerPass = pinnedPerPass
        self.removesMailDeletedElsewhere = removesMailDeletedElsewhere
        self.deletionChecksPerPass = deletionChecksPerPass
        self.pipelineStores = pipelineStores
        self.summaryBatch = summaryBatch
        self.bodyBatchMessages = bodyBatchMessages
        self.bodyBatchBytes = bodyBatchBytes
        self.idleTimeout = idleTimeout
        self.flagCheckInterval = flagCheckInterval
        self.reconnect = reconnect
    }
}

/// What an account's sync is doing, for the app to show as it is: never "up to date" while
/// mail is still missing, never silent about a stopped sync.
public struct SyncProgress: Sendable, Equatable {
    public enum Activity: Sendable, Equatable {
        case starting
        case connecting
        /// Downloading mail into a folder (its readable name).
        case importing(folder: String)
        /// Checking a folder for flag changes and messages removed at the provider.
        case checking(folder: String)
        /// Everything known is stored; waiting for changes in this folder (IDLE or polling).
        case watching(folder: String)
        /// The connection failed; the next attempt is at `retryAt`.
        case waitingToRetry(reason: String, retryAt: Date)
        /// The provider refused the password (revoked app password, changed password). The
        /// sync stops until the person signs in again.
        case signInFailed(reason: String)
        case stopped
    }

    public var activity: Activity = .starting
    /// Messages stored by this sync since it started.
    public var imported = 0
    /// Messages at the provider that are not stored yet (as of each folder's last listing).
    public var remaining = 0
    /// True when history stopped at the storage budget.
    public var historyPausedForBudget = false
    /// The history window in days (``SyncOptions/historyDays``); nil without one.
    public var historyDays: Int?
    /// Messages at the provider received before the history window that are not stored: left
    /// out by ``SyncOptions/historyDays`` (as of each folder's last listing).
    public var olderNotDownloaded = 0
    /// Messages too large to download; they stay at the provider.
    public var skippedTooLarge = 0
    /// Stored messages the provider no longer has, kept here and shown as deleted there
    /// (MAIL-075), and how many local copies "Remove mail deleted elsewhere" removed.
    public var deletedAtProvider = 0
    public var removedDeletedElsewhere = 0
    /// When the last complete pass over every folder finished.
    public var lastCompletedPass: Date?
    /// The provider's folders, after the first listing.
    public var folders: [SyncedFolder] = []

    public init() {}

    /// True while mail is still being downloaded.
    public var isImporting: Bool {
        if case .importing = activity { return true }
        return false
    }
}
