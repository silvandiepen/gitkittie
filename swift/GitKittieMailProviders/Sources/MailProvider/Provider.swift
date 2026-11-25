import Foundation

/// An authenticated, live connection to one account's mailboxes.
///
/// The provider adapter shape from Architecture.md, Boundaries and providers: folders,
/// incremental fetch, raw MIME, flags, moves, append and push, with no protocol types in the
/// signatures. IMAP is the first adapter (MailIMAP); a Gmail API or Graph adapter implements the
/// same protocol later. A session is used by one task at a time.
public protocol MailboxSession: AnyObject {
    var capabilities: ProviderCapabilities { get }

    func listFolders() async throws -> [RemoteFolder]
    func status(of folder: String) async throws -> FolderStatus
    func createFolder(_ folder: String) async throws
    func deleteFolder(_ folder: String) async throws

    /// Incremental sync: everything new since `cursor`, or the whole folder when `cursor` is nil
    /// or its UIDVALIDITY no longer matches (then ``FolderChanges/isReset`` is true).
    func changes(in folder: String, since cursor: SyncCursor?) async throws -> FolderChanges
    /// Current flags for every message in the folder, for flag reconciliation.
    func flags(in folder: String) async throws -> [RemoteMessageID: MessageFlags]
    func fetchMessage(_ id: RemoteMessageID) async throws -> FetchedMessage

    // Batched reads for the sync coordinator (GKM-011). Each call is one command; callers pick
    // the batch sizes, so no single response holds a whole folder. All ids in one call are in
    // one folder at one UIDVALIDITY; messages that are gone are left out of the result.

    /// Selects the folder and lists every UID in it, ascending.
    func listing(of folder: String) async throws -> FolderListing
    /// The UIDs, ascending, of the messages the provider received on or after `day` (IMAP
    /// `UID SEARCH SINCE`: the received date, INTERNALDATE, by calendar day, not the Date
    /// header), for the history window (GKM-039). Throws `commandFailed` when the folder no longer
    /// has `uidValidity`, since its UIDs would then name other messages.
    func uids(in folder: String, uidValidity: UInt32, receivedSince day: Date) async throws -> [UInt32]
    /// The folder's status and the UIDs, ascending, of its messages that match `criteria`
    /// (IMAP `UID SEARCH`), for searching mail that is not downloaded (GKM-041). Throws
    /// `folderNotFound` when the folder is gone.
    func search(_ criteria: RemoteSearchCriteria, in folder: String) async throws -> FolderListing
    /// Flags, size, dates and envelope for these messages.
    func summaries(of ids: [RemoteMessageID]) async throws -> [RemoteMessageSummary]
    /// The raw messages.
    func fetchMessages(_ ids: [RemoteMessageID]) async throws -> [FetchedMessage]
    /// Current flags of these messages.
    func flags(of ids: [RemoteMessageID]) async throws -> [RemoteMessageID: MessageFlags]
    /// The MIME structure of these messages (IMAP BODYSTRUCTURE), keyed by id (GKM-036).
    func bodyStructures(of ids: [RemoteMessageID]) async throws -> [RemoteMessageID: RemoteBodyPart]
    /// Sections of one message, by name: `"HEADER"` (the message header), `"1.MIME"` (a part's
    /// MIME header), `"1"` (a part's body as stored, still encoded). Sections the server returns
    /// nothing for are left out. Throws `messageNotFound` when the message is gone.
    func fetchSections(_ sections: [String], of id: RemoteMessageID) async throws -> [String: Data]
    /// The largest message the session can fetch; the sync skips and reports bigger ones.
    var maximumMessageSize: Int { get }

    func setFlags(_ flags: MessageFlags, _ change: FlagChange, on ids: [RemoteMessageID]) async throws
    /// Moves messages. Returns the new ids when the server reports them (UIDPLUS), keyed by old id.
    func move(_ ids: [RemoteMessageID], to folder: String) async throws -> [RemoteMessageID: RemoteMessageID]
    /// Copies messages; the originals stay. Returns the new ids when the server reports them
    /// (UIDPLUS), keyed by old id. Used where a move must never expunge the source: Gmail's
    /// All Mail, where an expunge can delete the message for good (MAIL-036).
    func copy(_ ids: [RemoteMessageID], to folder: String) async throws -> [RemoteMessageID: RemoteMessageID]
    /// Removes exactly these messages from their folder for good (IMAP: \Deleted, then
    /// UID EXPUNGE of these UIDs only). Throws `unsupported` when the server can only expunge
    /// every \Deleted message at once.
    func expunge(_ ids: [RemoteMessageID]) async throws
    /// CONDSTORE (RFC 7162): the flags of every message in the folder whose flags changed after
    /// `modSeq`, and the folder's HIGHESTMODSEQ. Throws `unsupported` without CONDSTORE.
    func flagChanges(in folder: String, uidValidity: UInt32, since modSeq: UInt64) async throws -> FlagChanges
    /// Stores a message in a folder (a Sent copy, a draft). Returns its id when the server
    /// reports it (UIDPLUS). `receivedAt` sets the provider's received date (IMAP APPEND
    /// date-time); `nil` lets the provider use the time of the append.
    func append(_ rawMessage: Data, to folder: String, flags: MessageFlags, receivedAt: Date?) async throws -> RemoteMessageID?
    /// Finds messages by their Message-ID header, for Sent reconciliation.
    func search(messageIDHeader: String, in folder: String) async throws -> [RemoteMessageID]

    /// Waits until the folder changes or `timeout` passes (IMAP IDLE, polling where the server
    /// has no IDLE).
    func waitForChanges(in folder: String, timeout: Duration) async throws -> MailboxEvent

    /// Logs out politely. The session cannot be used afterwards.
    func close() async
}

extension MailboxSession {
    /// Stores a message in a folder, received now.
    public func append(_ rawMessage: Data, to folder: String, flags: MessageFlags) async throws -> RemoteMessageID? {
        try await append(rawMessage, to: folder, flags: flags, receivedAt: nil)
    }
}

/// Opens sessions to one account. A connector holds no connection itself; sync code opens a
/// session, uses it, and opens a new one after a network failure (``ReconnectPolicy``).
public protocol MailboxConnector: Sendable {
    func withSession<Result>(_ body: (any MailboxSession) async throws -> Result) async throws -> Result
}

/// Errors every adapter maps its protocol failures onto, so callers can decide on retry
/// without knowing the protocol.
public enum MailProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    /// TCP connect or TLS handshake failed, including an untrusted certificate.
    case connectionFailed(String)
    /// The connection dropped while in use. Safe to reconnect and retry idempotent work.
    case connectionLost(String)
    /// The server rejected the credentials. Retrying with the same ones will not help.
    case authenticationFailed(String)
    /// The server does not offer something this operation requires (e.g. STARTTLS).
    case unsupported(String)
    /// The server answered NO or BAD.
    case commandFailed(String)
    case folderNotFound(String)
    case messageNotFound(RemoteMessageID)
    /// The server sent something this client could not make sense of.
    case protocolViolation(String)
    case timedOut(String)

    public var isConnectionProblem: Bool {
        switch self {
        case .connectionFailed, .connectionLost, .timedOut: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .connectionFailed(let s): "connection failed: \(s)"
        case .connectionLost(let s): "connection lost: \(s)"
        case .authenticationFailed(let s): "authentication failed: \(s)"
        case .unsupported(let s): "unsupported: \(s)"
        case .commandFailed(let s): "command failed: \(s)"
        case .folderNotFound(let s): "folder not found: \(s)"
        case .messageNotFound(let id): "message not found: \(id)"
        case .protocolViolation(let s): "protocol violation: \(s)"
        case .timedOut(let s): "timed out: \(s)"
        }
    }
}
