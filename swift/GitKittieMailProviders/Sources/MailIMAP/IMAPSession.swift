import Foundation
import MailProvider
import NIOCore
import NIOIMAP

/// A logged-in IMAP connection, as a ``MailboxSession``.
///
/// Every operation that takes ``RemoteMessageID``s first selects their folder and checks that
/// its UIDVALIDITY still matches: a UID from before a reset is never applied to whatever
/// message has that UID now.
public final class IMAPSession: MailboxSession {
    let wire: IMAPWire
    let log: MailLog
    public private(set) var capabilities: ProviderCapabilities
    private var rawCapabilities: Set<String>
    private var selected: SelectedFolder?
    private var isClosed = false

    struct SelectedFolder {
        var id: String
        var status: FolderStatus
    }

    private init(wire: IMAPWire, log: MailLog, capabilities: Set<String>) {
        self.wire = wire
        self.log = log
        self.rawCapabilities = capabilities
        self.capabilities = Self.providerCapabilities(capabilities)
    }

    static func open(wire: IMAPWire, credential: MailCredential, log: MailLog) async throws -> IMAPSession {
        let before = try await capabilityList(wire)
        let session = IMAPSession(wire: wire, log: log, capabilities: before)
        try await session.authenticate(credential)
        // Servers may advertise more once logged in.
        session.rawCapabilities = try await capabilityList(wire)
        session.capabilities = providerCapabilities(session.rawCapabilities)
        log.info("imap", "logged in; capabilities: \(session.rawCapabilities.sorted().joined(separator: " "))")
        return session
    }

    private static func capabilityList(_ wire: IMAPWire) async throws -> Set<String> {
        let result = try await wire.run(.capability, logAs: "CAPABILITY")
        try check(result, "CAPABILITY")
        var names = Set<String>()
        for case .capabilityData(let list) in result.untagged {
            for capability in list { names.insert(capability.name.uppercased()) }
        }
        return names
    }

    static func providerCapabilities(_ names: Set<String>) -> ProviderCapabilities {
        ProviderCapabilities(
            push: names.contains("IDLE"),
            atomicMove: names.contains("MOVE"),
            reportsNewIDs: names.contains("UIDPLUS"),
            changeTracking: names.contains("CONDSTORE") || names.contains("QRESYNC"),
            raw: names.sorted()
        )
    }

    private func authenticate(_ credential: MailCredential) async throws {
        let result: IMAPCommandResult
        switch credential {
        case .password(let username, let password):
            guard !rawCapabilities.contains("LOGINDISABLED") else {
                throw MailProviderError.unsupported("the server has disabled LOGIN on this connection")
            }
            let command = password.withValue { Command.login(username: username, password: $0) }
            result = try await wire.run(command, logAs: "LOGIN ‹user› \(Redaction.placeholder)")
        case .oauth2(let username, let token):
            guard rawCapabilities.contains("AUTH=XOAUTH2") else {
                throw MailProviderError.unsupported("the server does not offer AUTH=XOAUTH2")
            }
            result = try await wire.authenticate(
                mechanism: "XOAUTH2",
                initialResponse: token.withValue { SASL.xoauth2(username: username, accessToken: $0) }
            )
        }
        guard result.isOK else {
            throw MailProviderError.authenticationFailed(result.responseText.text)
        }
    }

    // MARK: - Folders

    public func listFolders() async throws -> [RemoteFolder] {
        let result = try await wire.run(.list(nil, reference: MailboxName(ByteBuffer()), .mailbox(ByteBuffer(string: "*")), []), logAs: "LIST \"\" *")
        try Self.check(result, "LIST")
        var folders: [RemoteFolder] = []
        for case .mailboxData(.list(let info)) in result.untagged {
            folders.append(Self.folder(from: info))
        }
        return folders
    }

    static func folder(from info: MailboxInfo) -> RemoteFolder {
        let id = String(decoding: info.path.name.bytes, as: UTF8.self)
        let attributes = info.attributes.map { String($0) }
        let lowered = Set(attributes.map { $0.lowercased() })
        let path = info.path.displayStringComponents()
        return RemoteFolder(
            id: id,
            path: path.isEmpty ? [id] : path,
            role: FolderRoles.role(id: id, displayName: path.last ?? id, attributes: lowered),
            isSelectable: !lowered.contains("\\noselect") && !lowered.contains("\\nonexistent"),
            attributes: attributes
        )
    }

    public func status(of folder: String) async throws -> FolderStatus {
        try await select(folder, refresh: true).status
    }

    public func createFolder(_ folder: String) async throws {
        let result = try await wire.run(.create(Self.mailbox(folder), []), logAs: "CREATE \(folder)")
        try Self.check(result, "CREATE \(folder)")
    }

    public func deleteFolder(_ folder: String) async throws {
        if selected?.id == folder {
            // Leave it first; some servers refuse to delete the selected mailbox.
            _ = try await select("INBOX", refresh: true)
        }
        let result = try await wire.run(.delete(Self.mailbox(folder)), logAs: "DELETE \(folder)")
        try Self.check(result, "DELETE \(folder)")
    }

    @discardableResult
    func select(_ folder: String, refresh: Bool = false) async throws -> SelectedFolder {
        if !refresh, let selected, selected.id == folder { return selected }
        selected = nil
        let result = try await wire.run(.select(Self.mailbox(folder), []), logAs: "SELECT \(folder)")
        guard result.isOK else {
            if case .nonExistent = result.responseText.code { throw MailProviderError.folderNotFound(folder) }
            throw MailProviderError.commandFailed("SELECT \(folder): \(result.responseText.text)")
        }
        var uidValidity: UInt32?
        var uidNext: UInt32?
        var exists = 0
        var highestModSeq: UInt64?
        for payload in result.untagged {
            switch payload {
            case .mailboxData(.exists(let count)): exists = count
            case .conditionalState(.ok(let text)):
                switch text.code {
                case .uidValidity(let value): uidValidity = UInt32(value)
                case .uidNext(let uid): uidNext = uid.rawValue
                case .highestModificationSequence(let value): highestModSeq = UInt64(value)
                default: break
                }
            default: break
            }
        }
        guard let uidValidity else {
            throw MailProviderError.protocolViolation("SELECT \(folder) returned no UIDVALIDITY")
        }
        let state = SelectedFolder(id: folder, status: FolderStatus(
            uidValidity: uidValidity, uidNext: uidNext, messageCount: exists, highestModSeq: highestModSeq
        ))
        selected = state
        _ = wire.takeUnsolicited()
        return state
    }

    /// Selects the folder of `ids` and makes sure they still refer to the same messages.
    func selectForMessages(_ ids: [RemoteMessageID]) async throws -> (folder: String, uids: [UInt32]) {
        guard let first = ids.first else { throw MailProviderError.commandFailed("no messages given") }
        guard ids.allSatisfy({ $0.folder == first.folder && $0.uidValidity == first.uidValidity }) else {
            throw MailProviderError.commandFailed("messages from different folders in one operation")
        }
        let state = try await select(first.folder)
        guard state.status.uidValidity == first.uidValidity else {
            // The folder was reset: these UIDs may now point at other messages.
            throw MailProviderError.messageNotFound(first)
        }
        return (first.folder, ids.map(\.uid))
    }

    // MARK: - Messages

    public func changes(in folder: String, since cursor: SyncCursor?) async throws -> FolderChanges {
        let listing = try await listing(of: folder)
        let status = listing.status
        let isReset = cursor == nil || cursor?.uidValidity != status.uidValidity || cursor?.folder != folder
        let after = isReset ? 0 : cursor!.highestFetchedUID
        if isReset, let cursor {
            log.warning("imap", "\(folder): UIDVALIDITY changed from \(cursor.uidValidity) to \(status.uidValidity); full resync")
        }
        // Summaries in batches: a folder with 100,000 messages is 200 commands of 500, not one
        // response the size of the folder's metadata held in memory at once.
        let newUIDs = listing.uids.filter { $0 > after }
        var summaries: [RemoteMessageSummary] = []
        for start in stride(from: 0, to: newUIDs.count, by: Self.summaryBatchSize) {
            let batch = newUIDs[start..<min(start + Self.summaryBatchSize, newUIDs.count)]
            summaries += try await self.summaries(of: batch.map { RemoteMessageID(folder: folder, uidValidity: status.uidValidity, uid: $0) })
        }
        summaries.sort { $0.id.uid < $1.id.uid }
        let highest = max(after, summaries.last?.id.uid ?? 0)
        return FolderChanges(
            isReset: isReset,
            status: status,
            newMessages: summaries,
            nextCursor: SyncCursor(folder: folder, uidValidity: status.uidValidity, highestFetchedUID: highest)
        )
    }

    public func flags(in folder: String) async throws -> [RemoteMessageID: MessageFlags] {
        let listing = try await listing(of: folder)
        var flags: [RemoteMessageID: MessageFlags] = [:]
        for start in stride(from: 0, to: listing.uids.count, by: Self.summaryBatchSize) {
            let batch = listing.uids[start..<min(start + Self.summaryBatchSize, listing.uids.count)]
            let ids = batch.map { RemoteMessageID(folder: folder, uidValidity: listing.status.uidValidity, uid: $0) }
            flags.merge(try await self.flags(of: ids)) { _, new in new }
        }
        return flags
    }

    public func fetchMessage(_ id: RemoteMessageID) async throws -> FetchedMessage {
        let (folder, uids) = try await selectForMessages([id])
        let result = try await wire.run(
            .uidFetch(.set(UIDSetNonEmpty(range: UIDRange(UID(rawValue: uids[0])))),
                      [.uid, .flags, .rfc822Size, .internalDate, .envelope, .bodySection(peek: true, .complete, nil)], []),
            logAs: "UID FETCH \(id.uid) (BODY.PEEK[]) in \(folder)"
        )
        try Self.check(result, "UID FETCH BODY")
        guard
            let fetch = result.fetches.first(where: { $0.uid == id.uid }),
            let summary = Self.summary(from: fetch, folder: folder, uidValidity: id.uidValidity),
            let body = fetch.body
        else { throw MailProviderError.messageNotFound(id) }
        return FetchedMessage(summary: summary, rawMessage: body)
    }

    public func setFlags(_ flags: MessageFlags, _ change: FlagChange, on ids: [RemoteMessageID]) async throws {
        guard !ids.isEmpty else { return }
        let (folder, uids) = try await selectForMessages(ids)
        let list = Self.imapFlags(flags)
        guard !list.isEmpty else { return }
        let data: StoreData = switch change {
        case .add: .flags(.add(silent: true, list: list))
        case .remove: .flags(.remove(silent: true, list: list))
        }
        let result = try await wire.run(.uidStore(.set(Self.uidSet(uids)), [], data),
                                        logAs: "UID STORE \(change == .add ? "+" : "-")FLAGS in \(folder)")
        try Self.check(result, "UID STORE")
    }

    public func move(_ ids: [RemoteMessageID], to destination: String) async throws -> [RemoteMessageID: RemoteMessageID] {
        guard !ids.isEmpty else { return [:] }
        let (folder, uids) = try await selectForMessages(ids)
        let set = Self.uidSet(uids)
        let target = Self.mailbox(destination)
        let result: IMAPCommandResult
        if rawCapabilities.contains("MOVE") {
            result = try await wire.run(.uidMove(.set(set), target), logAs: "UID MOVE \(uids.count) → \(destination)")
            try Self.check(result, "UID MOVE")
        } else if rawCapabilities.contains("UIDPLUS") {
            // COPY, then expunge exactly these UIDs (UID EXPUNGE never touches other messages
            // that happen to carry \Deleted).
            result = try await wire.run(.uidCopy(.set(set), target), logAs: "UID COPY \(uids.count) → \(destination)")
            try Self.check(result, "UID COPY")
            try Self.check(try await wire.run(.uidStore(.set(set), [], .flags(.add(silent: true, list: [.deleted]))), logAs: "UID STORE +FLAGS \\Deleted"), "UID STORE")
            try Self.check(try await wire.run(.uidExpunge(.set(set)), logAs: "UID EXPUNGE"), "UID EXPUNGE")
        } else {
            throw MailProviderError.unsupported("moving needs MOVE or UIDPLUS; a plain EXPUNGE could remove other messages")
        }
        _ = wire.takeUnsolicited()
        var mapping: [RemoteMessageID: RemoteMessageID] = [:]
        for case .uidCopy(let copy) in result.responseCodes {
            let sources = copy.sourceUIDs.flatMap { $0.range.lowerBound.rawValue...$0.range.upperBound.rawValue }
            let targets = copy.destinationUIDs.flatMap { $0.range.lowerBound.rawValue...$0.range.upperBound.rawValue }
            for (source, target) in zip(sources, targets) {
                guard let old = ids.first(where: { $0.uid == source }) else { continue }
                mapping[old] = RemoteMessageID(folder: destination, uidValidity: UInt32(copy.destinationUIDValidity), uid: target)
            }
        }
        _ = folder
        return mapping
    }

    public func append(_ rawMessage: Data, to folder: String, flags: MessageFlags) async throws -> RemoteMessageID? {
        let result = try await wire.append(rawMessage, to: Self.mailbox(folder), flags: Self.imapFlags(flags))
        guard result.isOK else {
            if case .tryCreate = result.responseText.code { throw MailProviderError.folderNotFound(folder) }
            throw MailProviderError.commandFailed("APPEND to \(folder): \(result.responseText.text)")
        }
        if selected?.id == folder { selected = nil } // its counts changed
        for case .uidAppend(let append) in result.responseCodes {
            if let uid = append.uids.set.ranges.first?.range.lowerBound.rawValue {
                return RemoteMessageID(folder: folder, uidValidity: UInt32(append.uidValidity), uid: uid)
            }
        }
        return nil
    }

    public func search(messageIDHeader: String, in folder: String) async throws -> [RemoteMessageID] {
        let wanted = MessageIDs.normalize(messageIDHeader)
        guard !wanted.isEmpty else { return [] }
        let state = try await select(folder, refresh: true)
        guard state.status.messageCount > 0 else { return [] }
        let result = try await wire.run(
            .uidSearch(key: .header("Message-ID", ByteBuffer(string: wanted))),
            logAs: "UID SEARCH HEADER Message-ID in \(folder)"
        )
        try Self.check(result, "UID SEARCH")
        var uids: [UInt32] = []
        for case .mailboxData(.search(let found, _)) in result.untagged {
            uids += found.map(\.rawValue)
        }
        guard !uids.isEmpty else { return [] }
        // HEADER search is a substring match (RFC 3501 6.4.4); keep exact matches only.
        let check = try await wire.run(.uidFetch(.set(Self.uidSet(uids)), [.uid, .envelope], []),
                                       logAs: "UID FETCH (ENVELOPE) for search check")
        try Self.check(check, "UID FETCH ENVELOPE")
        return check.fetches.compactMap { Self.summary(from: $0, folder: folder, uidValidity: state.status.uidValidity) }
            .filter { MessageIDs.normalize($0.messageIDHeader ?? "") == wanted }
            .map(\.id)
            .sorted { $0.uid < $1.uid }
    }

    public func waitForChanges(in folder: String, timeout: Duration) async throws -> MailboxEvent {
        let before = try await select(folder)
        if wire.takeUnsolicited().contains(where: Self.isChange) { return .changed }
        if rawCapabilities.contains("IDLE") {
            let event = try await wire.idle(timeout: timeout)
            if event == .changed { selected = nil }
            return event
        }
        // No IDLE: poll with NOOP.
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            try await Task.sleep(for: min(.seconds(15), end - clock.now))
            let result = try await wire.run(.noop, logAs: "NOOP")
            try Self.check(result, "NOOP")
            if result.untagged.contains(where: Self.isChange) || !result.fetches.isEmpty {
                selected = nil
                return .changed
            }
        }
        _ = before
        return .timedOut
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        if !wire.isBroken {
            _ = try? await wire.run(.logout, logAs: "LOGOUT")
        }
        await wire.close()
    }

    /// Drops the TCP connection without logging out, as a network failure would. The next
    /// operation fails with `connectionLost`.
    @_spi(FaultInjection) public func dropConnectionForTesting() {
        wire.dropForTesting()
    }

    // MARK: - Helpers

    private static func isChange(_ payload: ResponsePayload) -> Bool {
        switch payload {
        case .mailboxData(.exists), .messageData(.expunge), .messageData(.vanished): true
        default: false
        }
    }

    static func check(_ result: IMAPCommandResult, _ what: String) throws {
        guard result.isOK else {
            throw MailProviderError.commandFailed("\(what): \(result.responseText.text)")
        }
    }

    static func mailbox(_ id: String) -> MailboxName {
        MailboxName(Array(id.utf8))
    }

    static func uidSet(_ uids: [UInt32]) -> UIDSetNonEmpty {
        let set = UIDSet(uids.map { UIDRange(UID(rawValue: $0)) })
        return UIDSetNonEmpty(set: set)!
    }

    static func imapFlags(_ flags: MessageFlags) -> [Flag] {
        var list: [Flag] = []
        if flags.seen { list.append(.seen) }
        if flags.answered { list.append(.answered) }
        if flags.flagged { list.append(.flagged) }
        if flags.deleted { list.append(.deleted) }
        if flags.draft { list.append(.draft) }
        for keyword in flags.keywords.sorted() {
            if let flag = Flag(keyword) { list.append(flag) }
        }
        return list
    }

    static func messageFlags(_ flags: [Flag]) -> MessageFlags {
        var result = MessageFlags()
        for flag in flags {
            switch String(flag).lowercased() {
            case "\\seen": result.seen = true
            case "\\answered": result.answered = true
            case "\\flagged": result.flagged = true
            case "\\deleted": result.deleted = true
            case "\\draft": result.draft = true
            case "\\recent": break
            default: result.keywords.insert(String(flag))
            }
        }
        return result
    }

    static func summary(from fetch: IMAPFetchedAttributes, folder: String, uidValidity: UInt32) -> RemoteMessageSummary? {
        guard let uid = fetch.uid else { return nil }
        var summary = RemoteMessageSummary(
            id: RemoteMessageID(folder: folder, uidValidity: uidValidity, uid: uid),
            flags: MessageFlags(), size: nil, internalDate: nil, messageIDHeader: nil, subject: nil
        )
        for attribute in fetch.attributes {
            switch attribute {
            case .flags(let flags): summary.flags = messageFlags(flags)
            case .rfc822Size(let size): summary.size = size
            case .internalDate(let date): summary.internalDate = Self.date(date)
            case .envelope(let envelope):
                summary.messageIDHeader = envelope.messageID.map { String($0) }
                summary.subject = envelope.subject.map { String(buffer: $0) }
            default: break
            }
        }
        return summary
    }

    static func date(_ date: ServerMessageDate) -> Date? {
        let c = date.components
        var components = DateComponents()
        components.year = c.year
        components.month = c.month
        components.day = c.day
        components.hour = c.hour
        components.minute = c.minute
        components.second = c.second
        components.timeZone = TimeZone(secondsFromGMT: c.zoneMinutes * 60)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

/// Recognises what a folder is for. SPECIAL-USE attributes win; well-known names are the
/// fallback for servers without them.
public enum FolderRoles {
    public static func role(id: String, displayName: String, attributes: Set<String>) -> FolderRole? {
        if id.uppercased() == "INBOX" { return .inbox }
        let byAttribute: [(String, FolderRole)] = [
            ("\\sent", .sent), ("\\drafts", .drafts), ("\\trash", .trash), ("\\junk", .junk),
            ("\\archive", .archive), ("\\all", .all), ("\\flagged", .flagged),
        ]
        for (attribute, role) in byAttribute where attributes.contains(attribute) { return role }
        switch displayName.lowercased() {
        case "sent", "sent messages", "sent items", "sent mail": return .sent
        case "drafts": return .drafts
        case "trash", "deleted messages", "deleted items", "bin": return .trash
        case "junk", "spam", "junk e-mail": return .junk
        case "archive": return .archive
        default: return nil
        }
    }
}

public enum MessageIDs {
    /// `<abc@example.com>` and `abc@example.com` are the same id.
    public static func normalize(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { trimmed.removeFirst() }
        if trimmed.hasSuffix(">") { trimmed.removeLast() }
        return trimmed
    }
}

enum SASL {
    /// XOAUTH2 initial client response: "user=" user ^A "auth=Bearer " token ^A ^A. The codec
    /// base64-encodes it.
    static func xoauth2(username: String, accessToken: String) -> [UInt8] {
        Array("user=\(username)\u{1}auth=Bearer \(accessToken)\u{1}\u{1}".utf8)
    }
}
