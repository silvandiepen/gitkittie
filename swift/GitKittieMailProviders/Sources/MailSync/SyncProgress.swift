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
    /// History messages imported per pass before new mail is checked again.
    public var historyPerPass: Int
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

    public init(recentPerFolder: Int = 200, historyBudgetBytes: Int64? = nil, historyPerPass: Int = 500,
                summaryBatch: Int = 500, bodyBatchMessages: Int = 100, bodyBatchBytes: Int = 8 * 1024 * 1024,
                idleTimeout: Duration = .seconds(9 * 60), flagCheckInterval: Duration = .seconds(120),
                reconnect: ReconnectPolicy = ReconnectPolicy()) {
        self.recentPerFolder = recentPerFolder
        self.historyBudgetBytes = historyBudgetBytes
        self.historyPerPass = historyPerPass
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
    /// Messages too large to download; they stay at the provider.
    public var skippedTooLarge = 0
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
