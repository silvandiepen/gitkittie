import Foundation
import MailCore
import MailMIME
import MailProvider
import MailStore

/// A message at the provider that a search found and that is not stored here (GKM-041).
public struct ServerSearchHit: Sendable, Hashable, Identifiable {
    public var account: MailAccountID
    public var location: RemoteLocation
    /// The folder's readable name.
    public var folderName: String
    public var subject: String?
    /// The first sender's name, decoded, or nil when the envelope has none.
    public var senderName: String?
    public var senderAddress: String?
    /// The provider's received date.
    public var receivedAt: Date?
    /// The provider's size in octets.
    public var size: Int?
    public var isUnread: Bool
    public var isFlagged: Bool

    public init(account: MailAccountID, location: RemoteLocation, folderName: String, subject: String?, senderName: String?,
                senderAddress: String?, receivedAt: Date?, size: Int?, isUnread: Bool, isFlagged: Bool) {
        self.account = account
        self.location = location
        self.folderName = folderName
        self.subject = subject
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.receivedAt = receivedAt
        self.size = size
        self.isUnread = isUnread
        self.isFlagged = isFlagged
    }

    public var id: String { "\(account.rawValue)/\(location.mailbox)/\(location.uidValidity)/\(location.uid)" }

    /// The sender as a list shows it: the name, else the address.
    public var sender: String? { senderName ?? senderAddress }
}

/// What one account's server search found.
public struct ServerSearchResult: Sendable, Equatable {
    /// The newest matches that are not stored here, newest first, at most the searcher's limit.
    public var hits: [ServerSearchHit]
    /// Every match not stored here, including those beyond the limit.
    public var total: Int

    public init(hits: [ServerSearchHit], total: Int) {
        self.hits = hits
        self.total = total
    }
}

/// Searches one account's provider for mail that is not downloaded, and downloads a found
/// message when it is opened (GKM-041, MAIL-081..083).
///
/// - **Only where mail is left out.** It searches the folders whose history is not complete
///   here (the history window or the storage budget left mail at the provider); a folder that
///   is all here has nothing to find.
/// - **One connection.** Searches and downloads take turns on one connection at a time, beside
///   the sync's, the action replay's and on-demand attachments' (MAIL-082). A search that was
///   cancelled because a newer one started stops before the next folder, and the next one waits
///   for it to close its connection.
/// - **Capped.** At most ``limit`` messages are summarised and returned: the newest.
/// - **Stored like synced mail.** A downloaded message is stored as the sync stores it, under
///   the provider location it was found at, so the sync knows it and local search finds it.
public actor ServerSearcher {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No connection to the provider.
        case offline(String)
        /// The message is no longer where the search found it (deleted, moved, or the folder was
        /// reset): search again.
        case notAtProvider
        /// Too large to download here.
        case tooLarge
        case failed(String)

        public var description: String {
            switch self {
            case .offline: "You’re offline. Mail on the server can be searched and opened when you’re connected."
            case .notAtProvider: "This message is no longer where it was found on the server. Search again to find it."
            case .tooLarge: "This message is too large to download here."
            case .failed(let reason): "The server couldn’t be searched: \(reason)"
            }
        }
    }

    /// Most messages a search summarises and returns.
    public static let defaultLimit = 50

    public nonisolated let account: MailAccountID
    public nonisolated let limit: Int
    private let connector: any MailboxConnector
    private let store: MailStore
    private let onDemandThreshold: Int?
    private let log: MailLog
    /// The last search or download, which the next one waits for: one connection at a time.
    private var tail: Task<Void, Never>?

    public init(account: MailAccountID, connector: any MailboxConnector, store: MailStore, onDemandThreshold: Int?,
                limit: Int = ServerSearcher.defaultLimit, log: MailLog = .disabled) {
        self.account = account
        self.connector = connector
        self.store = store
        self.onDemandThreshold = onDemandThreshold
        self.limit = max(1, limit)
        self.log = log
    }

    // MARK: - Which folders

    /// The account's folders that have mail at the provider that is not stored here, as the
    /// last sync left them; only `mailbox` (any case) when given.
    public func foldersLeftOut(mailbox: String? = nil) async throws -> [SyncedFolder] {
        try await store.syncedFolders(account: account).filter { folder in
            !folder.historyComplete && folder.uidValidity != nil
                && (mailbox.map { folder.name.caseInsensitiveCompare($0) == .orderedSame } ?? true)
        }
    }

    // MARK: - Searching

    /// Searches every folder with mail left out (only `mailbox`, when given) for messages that
    /// match `criteria` and are not stored here. Returns nothing without words to search for:
    /// such a search would list whole folders.
    public func search(_ criteria: RemoteSearchCriteria, mailbox: String? = nil) async throws -> ServerSearchResult {
        guard !criteria.hasNoText else { return ServerSearchResult(hits: [], total: 0) }
        let folders = try await foldersLeftOut(mailbox: mailbox)
        guard !folders.isEmpty else { return ServerSearchResult(hits: [], total: 0) }
        guard case .found(let result) = try await serialized(.search(criteria, folders)) else { preconditionFailure() }
        return result
    }

    private func search(_ criteria: RemoteSearchCriteria, in folders: [SyncedFolder],
                        _ session: any MailboxSession) async throws -> ServerSearchResult {
        var total = 0
        var hits: [ServerSearchHit] = []
        for folder in folders {
            try Task.checkCancellation()
            let found: FolderListing
            do {
                found = try await session.search(criteria, in: folder.name)
            } catch MailProviderError.folderNotFound {
                continue // removed at the provider since the last sync
            }
            let known = try await store.knownUIDs(mailbox: folder.name, uidValidity: found.status.uidValidity, account: account)
            let missing = found.uids.filter { known[$0] == nil }
            guard !missing.isEmpty else { continue }
            total += missing.count
            // The newest by UID are the newest that arrived; summaries for those only.
            let newest = missing.suffix(limit)
            let ids = newest.map { RemoteMessageID(folder: folder.name, uidValidity: found.status.uidValidity, uid: $0) }
            for summary in try await session.summaries(of: ids) {
                if let after = criteria.receivedOnOrAfter, let date = summary.internalDate, date < after { total -= 1; continue }
                if let before = criteria.receivedBefore, let date = summary.internalDate, date >= before { total -= 1; continue }
                hits.append(Self.hit(summary, account: account, folderName: folder.displayName))
            }
        }
        hits.sort { ($0.receivedAt ?? .distantPast, $0.location.uid) > ($1.receivedAt ?? .distantPast, $1.location.uid) }
        log.debug("search", "\(account): \(total) messages at the provider match")
        return ServerSearchResult(hits: Array(hits.prefix(limit)), total: total)
    }

    static func hit(_ summary: RemoteMessageSummary, account: MailAccountID, folderName: String) -> ServerSearchHit {
        let id = summary.id
        let name = summary.fromName.map { EncodedWords.decode($0).trimmingCharacters(in: .whitespaces) }
        return ServerSearchHit(
            account: account, location: RemoteLocation(mailbox: id.folder, uidValidity: id.uidValidity, uid: id.uid),
            folderName: folderName, subject: summary.subject.map(EncodedWords.decode),
            senderName: name?.isEmpty == false ? name : nil, senderAddress: summary.fromAddress,
            receivedAt: summary.internalDate, size: summary.size, isUnread: !summary.flags.seen, isFlagged: summary.flags.flagged)
    }

    // MARK: - Downloading

    /// Downloads a found message and stores it as the sync would (a large one without its large
    /// attachments, GKM-036), under the location it was found at. Returns its local id; one that
    /// is stored meanwhile (by the sync, or an earlier open) is not downloaded again.
    public func download(_ hit: ServerSearchHit) async throws -> MailMessageID {
        precondition(hit.account == account, "a hit of another account")
        if let stored = try await store.localID(at: hit.location, account: account) { return stored }
        guard case .stored(let id) = try await serialized(.download(hit.location)) else { preconditionFailure() }
        return id
    }

    private func download(_ location: RemoteLocation, _ session: any MailboxSession) async throws -> MailMessageID {
        if let stored = try await store.localID(at: location, account: account) { return stored }
        let id = RemoteMessageID(folder: location.mailbox, uidValidity: location.uidValidity, uid: location.uid)
        let summaries: [RemoteMessageSummary]
        do {
            summaries = try await session.summaries(of: [id])
        } catch MailProviderError.messageNotFound, MailProviderError.folderNotFound {
            throw Failure.notAtProvider // the folder was reset or removed
        }
        guard let summary = summaries.first else { throw Failure.notAtProvider }
        if let threshold = onDemandThreshold, (summary.size ?? 0) > threshold,
           let structure = try await session.bodyStructures(of: [id])[id],
           let partial = try await SyncCoordinator.partialCopy(of: summary, structure: structure, threshold: threshold,
                                                               session, log: log),
           let outcome = try await store.storeSyncedPartials([partial], account: account).first ?? nil {
            log.debug("search", "stored a found message without its large attachments")
            return outcome.id
        }
        guard (summary.size ?? 0) <= session.maximumMessageSize else { throw Failure.tooLarge }
        guard let fetched = try await session.fetchMessages([id]).first else { throw Failure.notAtProvider }
        guard let outcome = try await store.storeSynced([SyncCoordinator.synced(fetched)], account: account).first else {
            throw Failure.failed("the message was not stored")
        }
        log.debug("search", "stored a found message")
        return outcome.id
    }

    // MARK: - One connection at a time

    private enum Work: Sendable {
        case search(RemoteSearchCriteria, [SyncedFolder])
        case download(RemoteLocation)
    }

    private enum Outcome: Sendable {
        case found(ServerSearchResult)
        case stored(MailMessageID)
    }

    /// Runs `work` in a session of its own once the previous search or download has finished,
    /// so this account never has more than one connection for them. Cancelling the caller
    /// cancels the work; connection problems are ``Failure/offline``.
    private func serialized(_ work: Work) async throws -> Outcome {
        let previous = tail
        let task = Task<Outcome, any Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await self.run(work)
        }
        tail = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func run(_ work: Work) async throws -> Outcome {
        do {
            return try await connector.withSession { session in
                switch work {
                case .search(let criteria, let folders): .found(try await self.search(criteria, in: folders, session))
                case .download(let location): .stored(try await self.download(location, session))
                }
            }
        } catch let error as MailProviderError {
            if error.isConnectionProblem { throw Failure.offline(error.description) }
            if case .messageNotFound = error { throw Failure.notAtProvider }
            throw Failure.failed(error.description)
        }
    }
}
