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

    func setFlags(_ flags: MessageFlags, _ change: FlagChange, on ids: [RemoteMessageID]) async throws
    /// Moves messages. Returns the new ids when the server reports them (UIDPLUS), keyed by old id.
    func move(_ ids: [RemoteMessageID], to folder: String) async throws -> [RemoteMessageID: RemoteMessageID]
    /// Stores a message in a folder (a Sent copy, a draft). Returns its id when the server
    /// reports it (UIDPLUS).
    func append(_ rawMessage: Data, to folder: String, flags: MessageFlags) async throws -> RemoteMessageID?
    /// Finds messages by their Message-ID header, for Sent reconciliation.
    func search(messageIDHeader: String, in folder: String) async throws -> [RemoteMessageID]

    /// Waits until the folder changes or `timeout` passes (IMAP IDLE, polling where the server
    /// has no IDLE).
    func waitForChanges(in folder: String, timeout: Duration) async throws -> MailboxEvent

    /// Logs out politely. The session cannot be used afterwards.
    func close() async
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
