import Foundation
import MailCore
import MailProvider
import MailStore

/// Fetches what partial messages left at the provider (GKM-036, MAIL-062): one attachment when
/// someone opens it, or a whole original to complete a message (pinned, exported, forwarded).
///
/// - **Once.** Asking for the same part again while it downloads waits for that download; once
///   stored it is read from the cache. The only remaining part of a message completes the
///   message instead (the same bytes over the wire, and the original is then stored).
/// - **Its own connection.** Each request opens a session of its own, so it neither waits for
///   nor disturbs the sync's IDLE.
/// - **Offline says so.** A connection problem is ``Failure/offline``, never a hang or a fake.
public actor OnDemandFetcher {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No connection to the provider: try again when online.
        case offline(String)
        /// The message is no longer at the provider (deleted or moved away): what it left there
        /// cannot be fetched any more.
        case notAtProvider
        /// The part is larger than can be held in memory.
        case tooLarge
        case failed(String)

        public var description: String {
            switch self {
            case .offline: "You’re offline. The attachment downloads when you’re connected."
            case .notAtProvider: "This message is no longer at your provider, so its attachment can’t be downloaded."
            case .tooLarge: "This attachment is too large to download here."
            case .failed(let reason): "The attachment couldn’t be downloaded: \(reason)"
            }
        }
    }

    public nonisolated let account: MailAccountID
    private let connector: any MailboxConnector
    private let store: MailStore
    private let log: MailLog
    private var inFlight: [String: Task<AttachmentReference, any Error>] = [:]
    private var completing: [MailMessageID: Task<Void, any Error>] = [:]

    public init(account: MailAccountID, connector: any MailboxConnector, store: MailStore, log: MailLog = .disabled) {
        self.account = account
        self.connector = connector
        self.store = store
        self.log = log
    }

    /// Fetches one left-out attachment and returns it as now stored (downloaded). When it is the
    /// message's last missing part, the whole message is completed instead and the same
    /// attachment of the complete message comes back.
    public func fetchAttachment(_ attachment: AttachmentReference, of id: MailMessageID) async throws -> AttachmentReference {
        guard let section = attachment.section else { return attachment } // a complete message's: nothing to fetch
        let key = "\(id.rawValue)#\(section)"
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await self.download(attachment, section: section, of: id) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Completes partial messages: downloads each one's whole original once and stores it.
    /// Returns how many were completed.
    @discardableResult
    public func complete(_ ids: [MailMessageID]) async throws -> Int {
        var count = 0
        for id in ids {
            if let running = completing[id] {
                try await running.value
                count += 1
                continue
            }
            let task = Task { try await self.completeOne(id) }
            completing[id] = task
            defer { completing[id] = nil }
            try await task.value
            count += 1
        }
        return count
    }

    /// Completes every partial message a pin covers in this account.
    @discardableResult
    public func downloadPinned() async throws -> Int {
        try await complete(store.pinnedPartialMessages(account: account))
    }

    // MARK: - Work

    private func download(_ wanted: AttachmentReference, section: String, of id: MailMessageID) async throws -> AttachmentReference {
        guard let status = try await store.partialStatus(id) else {
            return try await sameAttachment(as: wanted, in: id, at: nil) // completed meanwhile
        }
        let listed = try await store.message(id).front.attachments
        if let fetched = status.fetched[section], let stored = listed.first(where: { $0.section == section && $0.blob == fetched }) {
            return stored
        }
        guard status.missing.contains(where: { $0.section == section }) else { throw Failure.failed("no such part") }
        if status.missing.count == 1 {
            // Its last missing part: complete the message (about the same bytes over the wire).
            let position = listed.firstIndex { $0.section == section }
            try await completeOne(id)
            return try await sameAttachment(as: wanted, in: id, at: position)
        }
        return try await withConnection { session in
            for location in status.locations {
                let remote = RemoteMessageID(folder: location.mailbox, uidValidity: location.uidValidity, uid: location.uid)
                do {
                    let sections = try await session.fetchSections([section], of: remote)
                    guard let body = sections[section] else { continue }
                    let reference = try await self.store.storeFetchedPart(body, section: section, of: id)
                    self.log.debug("ondemand", "fetched part \(section) of \(id)")
                    return reference
                } catch MailProviderError.messageNotFound, MailProviderError.folderNotFound {
                    continue
                } catch MailProviderError.commandFailed {
                    continue // the folder's UIDVALIDITY moved on, or the server refused this one
                }
            }
            throw Failure.notAtProvider
        }
    }

    private func completeOne(_ id: MailMessageID) async throws {
        try await withConnection { session in
            let done = try await Self.complete([id], store: self.store, session: session, log: self.log)
            if done == 0, try await self.store.isPartial(id) { throw Failure.notAtProvider }
        }
    }

    /// The attachment of a now complete message that a partial copy listed as `wanted`: at the
    /// same position (a complete message lists the same attachments in the same order), or,
    /// when the position is not known, the first with the same name, type and Content-ID.
    private func sameAttachment(as wanted: AttachmentReference, in id: MailMessageID, at position: Int?) async throws -> AttachmentReference {
        let attachments = try await store.message(id).front.attachments
        if let position, position < attachments.count, attachments[position].fileName == wanted.fileName {
            return attachments[position]
        }
        guard let same = attachments.first(where: {
            $0.isDownloaded && $0.fileName == wanted.fileName && $0.mediaType == wanted.mediaType && $0.contentId == wanted.contentId
        }) else { throw Failure.failed("the attachment is not in the completed message") }
        return same
    }

    private func withConnection<T: Sendable>(_ body: (any MailboxSession) async throws -> T) async throws -> T {
        do {
            return try await connector.withSession { session in try await body(session) }
        } catch let error as Failure {
            throw error
        } catch let error as MailProviderError {
            if error.isConnectionProblem { throw Failure.offline(error.description) }
            if case .unsupported(let reason) = error, reason.contains("over the in-memory limit") { throw Failure.tooLarge }
            throw Failure.failed(error.description)
        }
    }

    /// Downloads the whole original of each partial message and completes it, from the first of
    /// its locations that still has it. Messages already complete, or gone from the provider,
    /// are skipped. Returns how many were completed.
    static func complete(_ ids: [MailMessageID], store: MailStore, session: any MailboxSession, log: MailLog) async throws -> Int {
        var completed = 0
        for id in ids {
            try Task.checkCancellation()
            guard let status = try await store.partialStatus(id) else { continue }
            for location in status.locations {
                let remote = RemoteMessageID(folder: location.mailbox, uidValidity: location.uidValidity, uid: location.uid)
                guard status.size <= session.maximumMessageSize else { break }
                let fetched: [FetchedMessage]
                do {
                    fetched = try await session.fetchMessages([remote])
                } catch MailProviderError.folderNotFound, MailProviderError.commandFailed {
                    continue
                }
                guard let message = fetched.first else { continue }
                try await store.completePartial(id, with: message.rawMessage)
                log.debug("ondemand", "completed \(id)")
                completed += 1
                break
            }
        }
        return completed
    }
}
