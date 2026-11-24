import Foundation
import MailCompose
import MailCore
import MailProvider
import MailStore

/// A point in a send where a test can stop the outbox as if the process were killed
/// (the same idea as MailStore's `WriteFaults`). Throwing from the hook leaves on disk exactly
/// what a killed process would leave; the next ``Outbox/open(folder:accounts:transport:configuration:faults:log:)``
/// recovers from it.
public enum OutboxStep: Sendable, Hashable {
    /// `sending` is on disk; nothing has gone out.
    case markedSending
    /// The SMTP transaction ended with this outcome; nothing about it is on disk yet.
    case submitted(SubmissionOutcome)
    /// `sent` is on disk; the Sent copy has not been dealt with.
    case markedSent
    /// The Sent copy was appended; that is not on disk yet.
    case appendedSentCopy
}

public struct OutboxFaults: Sendable {
    public var hook: (@Sendable (OutboxStep) throws -> Void)?
    public init(hook: (@Sendable (OutboxStep) throws -> Void)? = nil) { self.hook = hook }
    public static let none = OutboxFaults()
}

public enum OutboxError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Another process (a second copy of the app) owns this outbox. Only one may send.
    case ownedByAnotherProcess
    case notFound(OperationID)
    /// The action does not apply in this state (e.g. cancelling a send in flight).
    case notAllowed(action: String, state: OutboxState)
    /// Send Again was refused because the message turned up at the provider.
    case alreadyDelivered
    /// Send Again needs a check at the provider first, and that check could not run.
    case cannotCheck(String)
    case io(String)

    public var description: String {
        switch self {
        case .ownedByAnotherProcess: "Another copy of GitKittie Mail is sending from this Mac."
        case .notFound: "That message is no longer in the outbox."
        case .notAllowed(let action, let state): "Can’t \(action) a message that is \(state.rawValue)."
        case .alreadyDelivered: "The message is already in Sent, so it was not sent again."
        case .cannotCheck(let why): "Couldn’t check Sent first: \(why)"
        case .io(let why): why
        }
    }
}

/// The current time, injectable so tests never sleep.
public protocol OutboxClock: Sendable {
    func now() -> Date
}

public struct SystemClock: OutboxClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// The durable outbox (GKM-014; ThreatModel.md §6). Every message is sent at most once:
///
/// - A send is journalled (bytes, then the entry) before anything goes out; Send returns only
///   once it is on disk. A queued message never changes afterwards.
/// - `sending` is on disk before the SMTP connection opens. After a crash, a `sending` entry
///   becomes `uncertain`.
/// - Only an outcome that proves the server does not have the message (`notSent`) is retried
///   automatically, with the same bytes and Message-ID, with backoff.
/// - An `uncertain` send (the end of the message went out, no answer came back, or the app
///   stopped mid-send) is looked for at the provider by Message-ID. Found: sent. Not found: it
///   stays uncertain and visible until the person decides; Send Again checks once more first.
/// - The Sent copy is appended only for providers that do not file one, and only after a
///   search by Message-ID finds none, so a crash between append and record cannot duplicate it.
/// - One process owns the outbox (an exclusive lock on its folder).
public actor Outbox {
    public struct Configuration: Sendable {
        /// Automatic retries after temporary failures, before the send is marked failed.
        public var maximumAutomaticAttempts = 5
        public var backoff = ReconnectPolicy(maxAttempts: 5, initialDelay: .seconds(30), maxDelay: .seconds(900), jitter: 0.2)
        /// How long to wait for a provider's own Sent copy under ``SentCopyPolicy/detect``.
        public var sentCopyDetectionWindow: TimeInterval = 120
        /// How often to look again for that copy inside the window.
        public var sentCopyCheckInterval: TimeInterval = 20
        /// How often an uncertain send is looked for again, and for how long.
        public var reconcileInterval: TimeInterval = 300
        public var reconcileFor: TimeInterval = 7 * 24 * 3600
        /// Completed sends stay in the journal this long, then are removed.
        public var keepCompleted: TimeInterval = 24 * 3600
        public var clock: any OutboxClock = SystemClock()
        /// 0..<1, for backoff jitter. Fixed in tests.
        public var random: @Sendable () -> Double = { Double.random(in: 0..<1) }

        public init() {}
    }

    public nonisolated let folder: URL
    private let accounts: any SendingAccountDirectory
    private let transport: any OutboxTransport
    private let configuration: Configuration
    private let faults: OutboxFaults
    private let log: MailLog
    private var lock: Int32
    private var entriesByID: [OperationID: OutboxEntry] = [:]
    private var inFlight: Set<OperationID> = []
    private var isProcessing = false
    /// Set when a fault hook stopped the outbox: like a dead process, it does nothing more.
    private var stopped = false
    private var observers: [UUID: AsyncStream<[OutboxEntry]>.Continuation] = [:]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Opens the journal in `folder` (`StoreLocations.outboxFolder`), takes the lock and
    /// recovers what a crash left: half-written sends are removed (Send never returned for
    /// them, so the draft still exists), and `sending` becomes `uncertain`.
    public static func open(folder: URL, accounts: any SendingAccountDirectory, transport: any OutboxTransport,
                            configuration: Configuration = Configuration(), faults: OutboxFaults = .none,
                            log: MailLog = .disabled) throws -> Outbox {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockPath = folder.appendingPathComponent(".lock").path
        let fd = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OutboxError.io("Can’t open the outbox lock (errno \(errno)).") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw OutboxError.ownedByAnotherProcess
        }
        do {
            let entries = try recover(folder: folder, now: configuration.clock.now(), keepCompleted: configuration.keepCompleted)
            return Outbox(folder: folder, accounts: accounts, transport: transport, configuration: configuration,
                          faults: faults, log: log, lock: fd, entries: entries)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private init(folder: URL, accounts: any SendingAccountDirectory, transport: any OutboxTransport,
                 configuration: Configuration, faults: OutboxFaults, log: MailLog, lock: Int32, entries: [OutboxEntry]) {
        self.folder = folder
        self.accounts = accounts
        self.transport = transport
        self.configuration = configuration
        self.faults = faults
        self.log = log
        self.lock = lock
        self.entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    /// Lets go of the folder, as a process exit would. The outbox does nothing afterwards.
    public func close() {
        stopped = true
        if lock >= 0 {
            Darwin.close(lock)
            lock = -1
        }
        for continuation in observers.values { continuation.finish() }
        observers = [:]
    }

    // MARK: - Reading

    /// Every send in the journal, oldest first.
    public func entries() -> [OutboxEntry] {
        entriesByID.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func entry(_ id: OperationID) -> OutboxEntry? { entriesByID[id] }

    /// The exact bytes queued for `id`.
    public func rawMessage(_ id: OperationID) throws -> Data {
        try Data(contentsOf: directory(of: id).appendingPathComponent("message.eml"))
    }

    /// The journal's contents after every change, starting with the current ones.
    public func updates() -> AsyncStream<[OutboxEntry]> {
        let (stream, continuation) = AsyncStream<[OutboxEntry]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        observers[key] = continuation
        continuation.yield(entries())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(key) }
        }
        return stream
    }

    private func removeObserver(_ key: UUID) { observers[key] = nil }

    // MARK: - Intents

    /// Journals a composed message for sending. When this returns, the message is on disk and
    /// will be sent (or shown as failed or uncertain); the caller may delete the draft.
    @discardableResult
    public func enqueue(_ message: ComposedMessage, account: MailAccountID, draft: ComposeDraft?) throws -> OutboxEntry {
        let now = configuration.clock.now()
        let id = OperationID()
        let parsedTo = draft.map { ($0.to + $0.cc).map(\.address) } ?? message.recipients.filter { !message.bcc.contains($0) }
        let entry = OutboxEntry(
            id: id, account: account, messageID: message.messageID, envelopeFrom: message.envelopeFrom,
            recipients: message.recipients, bcc: message.bcc, subject: draft?.subject ?? "",
            visibleRecipients: parsedTo, draft: draft, state: .queued, attempts: 0, nextAttemptAt: now,
            lastError: nil, sentCopy: .pending, sentAt: nil, lastReconciledAt: nil, createdAt: now, updatedAt: now,
            history: [OutboxTransition(state: .queued, at: now, note: nil)])
        let directory = directory(of: id)
        // The bytes first, then the entry: an entry on disk always has its message.
        try DurableFile.write(message.rawMessage, to: directory.appendingPathComponent("message.eml"))
        try persist(entry)
        log.info("outbox", "queued \(id) <\(message.messageID)> for \(message.recipients.count) recipient(s)")
        return entry
    }

    /// Runs everything that is due: queued sends, Sent copies, and checks on uncertain sends.
    /// Safe to call often; a second call while one runs returns at once.
    public func processDue() async {
        guard !stopped, !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        do {
            for entry in entries() where !stopped {
                try await step(entry.id)
            }
            try pruneCompleted()
        } catch is SimulatedStop {
            stopped = true
        } catch {
            log.error("outbox", "processing stopped: \(error)")
        }
    }

    /// A failed send goes back to the queue, with its attempts reset.
    public func retry(_ id: OperationID) throws {
        guard var entry = entriesByID[id] else { throw OutboxError.notFound(id) }
        guard entry.canRetry else { throw OutboxError.notAllowed(action: "retry", state: entry.state) }
        entry.attempts = 0
        entry.lastError = nil
        try transition(&entry, to: .queued, note: "retry requested", next: configuration.clock.now())
    }

    /// The person's decision on an uncertain send, after it was not found at the provider.
    /// Looks once more first; if it is there now, the send is marked sent instead. The resend
    /// uses the same bytes and Message-ID, so recipients' mail apps can tell the two apart.
    @discardableResult
    public func sendAgain(_ id: OperationID) async throws -> OutboxEntry {
        guard var entry = entriesByID[id] else { throw OutboxError.notFound(id) }
        guard entry.canSendAgain, !inFlight.contains(id) else { throw OutboxError.notAllowed(action: "send again", state: entry.state) }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        switch try await lookUp(entry) {
        case .found(let inSent, let policy):
            try markFound(&entry, inSent: inSent, policy: policy)
            throw OutboxError.alreadyDelivered
        case .notFound:
            entry.lastError = nil
            try transition(&entry, to: .queued, note: "sent again by the person after Sent showed nothing", next: configuration.clock.now())
            return entry
        case .unavailable(let why):
            throw OutboxError.cannotCheck(why)
        }
    }

    /// Checks an uncertain send at the provider now.
    @discardableResult
    public func reconcile(_ id: OperationID) async throws -> OutboxEntry {
        guard var entry = entriesByID[id] else { throw OutboxError.notFound(id) }
        guard entry.state == .uncertain, !inFlight.contains(id) else { return entry }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        try await reconcile(&entry)
        return entry
    }

    /// Takes a send out of the outbox. Not while it is in flight and not once sent. Returns the
    /// entry and its bytes, so the caller can put the draft back.
    public func cancel(_ id: OperationID) throws -> (entry: OutboxEntry, rawMessage: Data) {
        guard let entry = entriesByID[id] else { throw OutboxError.notFound(id) }
        guard entry.canCancel, !inFlight.contains(id) else { throw OutboxError.notAllowed(action: "cancel", state: entry.state) }
        let raw = (try? rawMessage(id)) ?? Data()
        try remove(id)
        log.info("outbox", "cancelled \(id) in state \(entry.state.rawValue)")
        return (entry, raw)
    }

    // MARK: - The state machine

    private func step(_ id: OperationID) async throws {
        guard var entry = entriesByID[id], !inFlight.contains(id) else { return }
        let now = configuration.clock.now()
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        switch entry.state {
        case .queued where (entry.nextAttemptAt ?? now) <= now:
            try await send(&entry)
        case .sent where entry.sentCopy == .pending && (entry.nextAttemptAt ?? now) <= now:
            try await fileSentCopy(&entry)
        case .uncertain:
            let due = entry.lastReconciledAt.map { now.timeIntervalSince($0) >= configuration.reconcileInterval } ?? true
            let stillWorthIt = now.timeIntervalSince(entry.sentAt ?? entry.updatedAt) < configuration.reconcileFor
            if due && stillWorthIt { try await reconcile(&entry) }
        case .sending:
            // Only `recover` and `send` see this state; nothing else may act on it.
            break
        default:
            break
        }
    }

    private func send(_ entry: inout OutboxEntry) async throws {
        guard let account = try await sendingAccount(for: entry) else { return }
        let raw: Data
        do {
            raw = try rawMessage(entry.id)
        } catch {
            entry.lastError = "The queued message can’t be read from disk."
            try transition(&entry, to: .failed, note: entry.lastError)
            return
        }

        let submitter: any MailSubmitter
        do {
            submitter = try await transport.submitter(for: account)
        } catch {
            // Nothing went out: no credential, or no settings.
            try await notSent(&entry, reason: "Couldn’t prepare the connection: \(error)", permanent: false)
            return
        }

        entry.attempts += 1
        try transition(&entry, to: .sending, note: "attempt \(entry.attempts)")
        try faults.hook?(.markedSending)

        let outcome = await submitter.submit(OutgoingMessage(
            messageID: entry.messageID, envelopeFrom: entry.envelopeFrom, recipients: entry.recipients, rawMessage: raw))
        try faults.hook?(.submitted(outcome))

        switch SubmissionFollowUp.after(outcome, providerSavesSentCopy: account.sentCopy == .providerFiles) {
        case .markSent:
            try markSent(&entry, policy: account.sentCopy, note: "accepted")
            try faults.hook?(.markedSent)
            try await fileSentCopy(&entry)
        case .retryLater, .failed:
            guard case .notSent(let reason, let permanent) = outcome else { return }
            try await notSent(&entry, reason: reason, permanent: permanent)
        case .reconcile:
            guard case .uncertain(let reason) = outcome else { return }
            entry.lastError = "No answer after the message went out (\(reason)). It may have been sent."
            try transition(&entry, to: .uncertain, note: reason)
            try await reconcile(&entry)
        }
    }

    private func notSent(_ entry: inout OutboxEntry, reason: String, permanent: Bool) async throws {
        entry.lastError = reason
        if permanent || entry.attempts >= configuration.maximumAutomaticAttempts {
            try transition(&entry, to: .failed, note: reason)
        } else {
            let delay = configuration.backoff.delay(beforeRetry: max(1, entry.attempts), random: configuration.random())
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            try transition(&entry, to: .queued, note: "not sent: \(reason)",
                           next: configuration.clock.now().addingTimeInterval(seconds))
        }
    }

    private func markSent(_ entry: inout OutboxEntry, policy: SentCopyPolicy, note: String) throws {
        let now = configuration.clock.now()
        entry.sentAt = entry.sentAt ?? now
        entry.lastError = nil
        switch policy {
        case .providerFiles: entry.sentCopy = .filedByProvider
        case .none: entry.sentCopy = .notKept
        case .append, .detect: entry.sentCopy = .pending
        }
        try transition(&entry, to: .sent, note: note, next: entry.sentCopy == .pending ? now : nil)
    }

    // MARK: - Reconciliation

    enum LookUp {
        /// `inSent`: the copy is in the Sent folder (not only in the inbox).
        case found(inSent: Bool, policy: SentCopyPolicy)
        case notFound
        case unavailable(String)
    }

    private func reconcile(_ entry: inout OutboxEntry) async throws {
        let result = try await lookUp(entry)
        entry.lastReconciledAt = configuration.clock.now()
        switch result {
        case .found(let inSent, let policy):
            try markFound(&entry, inSent: inSent, policy: policy)
            try await fileSentCopy(&entry)
        case .notFound:
            entry.lastError = "Not found in Sent. It may not have been sent; it was not sent again."
            try persist(entry)
            log.warning("outbox", "\(entry.id) <\(entry.messageID)> still uncertain: not at the provider")
        case .unavailable(let why):
            entry.lastError = "Couldn’t check Sent: \(why)"
            try persist(entry)
        }
    }

    private func markFound(_ entry: inout OutboxEntry, inSent: Bool, policy: SentCopyPolicy) throws {
        try markSent(&entry, policy: policy, note: "found at the provider")
        if inSent, entry.sentCopy == .pending {
            entry.sentCopy = .filedByProvider
            entry.nextAttemptAt = nil
            try persist(entry)
        }
    }

    /// Looks for the Message-ID in Sent and the "all mail" folder, and in the inbox when the
    /// message went to the account itself. Finding it proves the provider took it.
    private func lookUp(_ entry: OutboxEntry) async throws -> LookUp {
        let account: any SendingAccount
        do {
            guard let found = try await accounts.sendingAccount(entry.account) else { return .unavailable("the account is not set up on this Mac") }
            account = found
        } catch {
            return .unavailable("\(error)")
        }
        do {
            guard let connector = try await transport.mailbox(for: account) else {
                return .unavailable("the account has no mailbox access")
            }
            let own = Set(account.identities.map { $0.address.lowercased() } + [entry.envelopeFrom.lowercased()])
            let toSelf = entry.recipients.contains { own.contains($0.lowercased()) }
            let messageID = entry.messageID
            return try await connector.withSession { session -> LookUp in
                let folders = try await session.listFolders()
                let sent = Self.sentFolder(account, in: folders)
                var search: [String] = sent.map { [$0] } ?? []
                search += folders.filter { $0.role == .all && $0.isSelectable }.map(\.id)
                if toSelf { search.append(folders.first { $0.role == .inbox }?.id ?? "INBOX") }
                var foundInSent = false
                var foundAnywhere = false
                for folder in Self.unique(search) {
                    if case .found = try await SendReconciler.reconcile(messageID: messageID, in: [folder], session: session) {
                        foundAnywhere = true
                        if folder == sent { foundInSent = true }
                    }
                }
                return foundAnywhere ? .found(inSent: foundInSent, policy: account.sentCopy) : .notFound
            }
        } catch {
            return .unavailable("\(error)")
        }
    }

    // MARK: - The Sent copy

    private func fileSentCopy(_ entry: inout OutboxEntry) async throws {
        guard entry.state == .sent, entry.sentCopy == .pending else { return }
        guard let account = try await accounts.sendingAccount(entry.account) else {
            entry.nextAttemptAt = configuration.clock.now().addingTimeInterval(configuration.reconcileInterval)
            try persist(entry)
            return
        }
        switch account.sentCopy {
        case .providerFiles:
            entry.sentCopy = .filedByProvider
            entry.nextAttemptAt = nil
            try persist(entry)
            return
        case .none:
            entry.sentCopy = .notKept
            entry.nextAttemptAt = nil
            try persist(entry)
            return
        case .append, .detect:
            break
        }

        let raw = try rawMessage(entry.id)
        let messageID = entry.messageID
        let now = configuration.clock.now()
        let waitForProvider = account.sentCopy == .detect
            && now.timeIntervalSince(entry.sentAt ?? now) < configuration.sentCopyDetectionWindow
        enum Result { case alreadyThere, appended, wait, noFolder }
        let result: Result
        do {
            guard let connector = try await transport.mailbox(for: account) else {
                entry.sentCopy = .notKept
                entry.nextAttemptAt = nil
                entry.lastError = "No mailbox access: no copy kept in Sent."
                try persist(entry)
                return
            }
            let faults = self.faults
            result = try await connector.withSession { session -> Result in
                let folders = try await session.listFolders()
                guard let sent = Self.sentFolder(account, in: folders) else { return .noFolder }
                // Search before append: after a crash between the append and its record, the
                // copy is already there and must not be added twice.
                if !(try await session.search(messageIDHeader: messageID, in: sent)).isEmpty { return .alreadyThere }
                if waitForProvider { return .wait }
                _ = try await session.append(raw, to: sent, flags: MessageFlags(seen: true))
                try faults.hook?(.appendedSentCopy)
                return .appended
            }
        } catch is SimulatedStop {
            throw SimulatedStop()
        } catch {
            entry.lastError = "Sent, but the copy in Sent is not saved yet: \(error)"
            entry.nextAttemptAt = now.addingTimeInterval(configuration.sentCopyCheckInterval)
            try persist(entry)
            return
        }
        switch result {
        case .alreadyThere:
            // Under `detect`, the provider filed it, or this outbox did just before a crash.
            entry.sentCopy = .alreadyThere
            entry.nextAttemptAt = nil
        case .appended:
            entry.sentCopy = .appended
            entry.nextAttemptAt = nil
        case .wait:
            entry.nextAttemptAt = now.addingTimeInterval(configuration.sentCopyCheckInterval)
        case .noFolder:
            entry.sentCopy = .notKept
            entry.nextAttemptAt = nil
            entry.lastError = "Sent. The account has no Sent folder, so no copy was kept."
        }
        entry.lastError = result == .noFolder ? entry.lastError : nil
        try persist(entry)
    }

    // MARK: - Helpers

    private func sendingAccount(for entry: OutboxEntry) async throws -> (any SendingAccount)? {
        var entry = entry
        do {
            if let account = try await accounts.sendingAccount(entry.account) { return account }
            entry.lastError = "The account isn’t set up for sending on this Mac."
        } catch {
            entry.lastError = "The account’s settings can’t be read: \(error)"
        }
        entry.nextAttemptAt = configuration.clock.now().addingTimeInterval(configuration.reconcileInterval)
        try persist(entry)
        return nil
    }

    static func sentFolder(_ account: any SendingAccount, in folders: [RemoteFolder]) -> String? {
        if let name = account.sentFolder, folders.contains(where: { $0.id == name }) { return name }
        return folders.first { $0.role == .sent && $0.isSelectable }?.id
    }

    static func unique(_ folders: [String]) -> [String] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0).inserted }
    }

    private func transition(_ entry: inout OutboxEntry, to state: OutboxState, note: String? = nil, next: Date? = nil) throws {
        let now = configuration.clock.now()
        entry.state = state
        entry.nextAttemptAt = next
        entry.history.append(OutboxTransition(state: state, at: now, note: note))
        if entry.history.count > 50 { entry.history.removeFirst(entry.history.count - 50) }
        try persist(entry)
        log.info("outbox", "\(entry.id) → \(state.rawValue)\(note.map { " (\($0))" } ?? "")")
    }

    private func persist(_ entry: OutboxEntry) throws {
        guard !stopped else { throw SimulatedStop() }
        var entry = entry
        entry.updatedAt = configuration.clock.now()
        try DurableFile.write(Self.encoder.encode(entry), to: directory(of: entry.id).appendingPathComponent("entry.json"))
        entriesByID[entry.id] = entry
        publish()
    }

    private func remove(_ id: OperationID) throws {
        let directory = directory(of: id)
        // The entry first: without it, the folder is a leftover that `recover` removes.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("entry.json"))
        try DurableFile.syncDirectory(directory)
        try FileManager.default.removeItem(at: directory)
        entriesByID[id] = nil
        publish()
    }

    private func pruneCompleted() throws {
        let now = configuration.clock.now()
        for entry in entriesByID.values where entry.isComplete && now.timeIntervalSince(entry.updatedAt) > configuration.keepCompleted {
            try remove(entry.id)
        }
    }

    private func publish() {
        let snapshot = entries()
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    private func directory(of id: OperationID) -> URL {
        folder.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// What a relaunch finds on disk, made consistent.
    private static func recover(folder: URL, now: Date, keepCompleted: TimeInterval) throws -> [OutboxEntry] {
        var entries: [OutboxEntry] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            guard let id = OperationID(name), id.rawValue == name else { continue }
            let directory = folder.appendingPathComponent(name, isDirectory: true)
            try DurableFile.removePartials(in: directory)
            let entryURL = directory.appendingPathComponent("entry.json")
            guard FileManager.default.fileExists(atPath: entryURL.path) else {
                // Enqueue stopped before its entry was written: Send never returned, the draft
                // still exists. Nothing was ever sent from here.
                try FileManager.default.removeItem(at: directory)
                continue
            }
            var entry = try decoder.decode(OutboxEntry.self, from: Data(contentsOf: entryURL))
            if entry.state == .sending {
                // The app stopped mid-send. The server may have the message: never resend
                // blindly; look for it first.
                entry.state = .uncertain
                entry.lastError = "GitKittie Mail stopped while sending. It may have been sent."
                entry.lastReconciledAt = nil
                entry.history.append(OutboxTransition(state: .uncertain, at: now, note: "recovered after the app stopped mid-send"))
                entry.updatedAt = now
                try DurableFile.write(encoder.encode(entry), to: entryURL)
            }
            entries.append(entry)
        }
        return entries
    }
}

/// Thrown by a fault hook in tests to stop the outbox where a killed process would stop.
public struct SimulatedStop: Error, Sendable {
    public init() {}
}
