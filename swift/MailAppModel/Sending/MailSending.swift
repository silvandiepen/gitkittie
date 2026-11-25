import Foundation
import MailCompose
import MailCore
import MailMIME
import MailOutbox
import MailProvider
import MailStore
import Observation

/// An address the person can send as, and the account it belongs to.
struct SendingIdentity: Hashable, Identifiable {
    var account: MailAccountID
    var address: MailAddress
    var id: String { account.rawValue + "/" + address.address.lowercased() }
}

/// The accounts that can send on this Mac. Account setup (GKM-010) registers each account's
/// SMTP/IMAP settings and credential here; until it has, a queued message waits, visibly.
actor SendingAccountRegistry: SendingAccountDirectory {
    private var settings: [MailAccountID: SendingAccountSettings] = [:]

    func register(_ account: SendingAccountSettings) { settings[account.accountID] = account }
    func remove(_ id: MailAccountID) { settings[id] = nil }
    func all() -> [SendingAccountSettings] { Array(settings.values) }

    func sendingAccount(_ id: MailAccountID) async throws -> (any SendingAccount)? { settings[id] }
}

/// Drafts and the outbox, for the window (GKM-013, GKM-014). UI-free: views render it and send
/// intents back. Owned by ``AppModel``; one per app.
@MainActor
@Observable
final class MailSending {
    enum OutboxAvailability: Equatable {
        case ready
        /// Another copy of the app owns the outbox; this one does not send.
        case unavailable(String)
    }

    private(set) var drafts: [ComposeDraft] = []
    private(set) var outbox: [OutboxEntry] = []
    private(set) var outboxAvailability: OutboxAvailability = .ready
    /// Shown in an alert, then cleared.
    var lastError: String?

    let draftStore: DraftStore
    let registry: SendingAccountRegistry
    @ObservationIgnored private let outboxActor: Outbox?
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    /// How often the outbox looks for due work while the app runs.
    @ObservationIgnored var pumpInterval: Duration = .seconds(30)

    /// The sends that still need something: everything but a finished send.
    var pending: [OutboxEntry] { outbox.filter { !$0.isComplete } }
    /// Failed or uncertain: the person has to look.
    var needsAttention: [OutboxEntry] { outbox.filter { $0.state == .failed || $0.state == .uncertain } }

    init(locations: StoreLocations, registry: SendingAccountRegistry = SendingAccountRegistry(),
         credentials: any CredentialProvider, configuration: Outbox.Configuration = Outbox.Configuration()) throws {
        self.draftStore = try DraftStore(locations: locations)
        self.registry = registry
        do {
            self.outboxActor = try Outbox.open(folder: locations.outboxFolder, accounts: registry,
                                               transport: NetworkOutboxTransport(credentials: credentials),
                                               configuration: configuration)
        } catch let error as OutboxError {
            self.outboxActor = nil
            self.outboxAvailability = .unavailable(error.description)
        }
    }

    /// Starts following the outbox and running it in the background.
    func start() {
        guard observeTask == nil, let outboxActor else { return }
        observeTask = Task { [weak self] in
            for await entries in await outboxActor.updates() {
                self?.outbox = entries
            }
        }
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                await outboxActor.processDue()
                guard let interval = self?.pumpInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() async {
        observeTask?.cancel()
        pumpTask?.cancel()
        observeTask = nil
        pumpTask = nil
        await outboxActor?.close()
    }

    // MARK: - Identities

    /// Every address the person can send as: each account's own address first.
    func identities(accounts: [MailAccount]) async -> [SendingIdentity] {
        var out: [SendingIdentity] = []
        let registered = await registry.all()
        for account in accounts {
            let settings = registered.first { $0.accountID == account.id }
            let addresses = settings?.identities ?? [account.sendingAddress]
            out += addresses.filter { !$0.address.isEmpty }.map { SendingIdentity(account: account.id, address: $0) }
        }
        return out
    }

    // MARK: - Drafts

    func refreshDrafts() async {
        do {
            drafts = try await draftStore.drafts()
        } catch {
            lastError = "Drafts couldn’t be read: \(error)"
        }
    }

    /// A new, empty message from `identity` (or the first account).
    func newDraft(from identity: SendingIdentity?) async throws -> DraftID {
        let draft = ComposeDraft(account: identity?.account, from: identity?.address)
        return try await create(draft, attachments: [])
    }

    /// Reply or Reply All to a stored message, from the address it was sent to.
    func replyDraft(to original: Data, source: MailMessageID, account: MailAccountID,
                    identities: [SendingIdentity], all: Bool) async throws -> DraftID {
        let message = MIMEParser.parse(original)
        let builder = ReplyBuilder(ownAddresses: Self.addresses(of: account, in: identities), account: account)
        return try await create(builder.reply(to: message, mode: all ? .replyAll : .reply, source: source), attachments: [])
    }

    /// Forward a stored message, with its attachments.
    func forwardDraft(of original: Data, source: MailMessageID, account: MailAccountID,
                      identities: [SendingIdentity]) async throws -> DraftID {
        let message = MIMEParser.parse(original)
        let builder = ReplyBuilder(ownAddresses: Self.addresses(of: account, in: identities), account: account)
        let (draft, attachments) = builder.forward(message, source: source)
        return try await create(draft, attachments: attachments)
    }

    func draft(_ id: DraftID) async -> ComposeDraft? {
        try? await draftStore.draft(id)
    }

    func save(_ draft: ComposeDraft) async throws -> DraftSaveResult {
        let result = try await draftStore.save(draft)
        await refreshDrafts()
        return result
    }

    func addAttachment(_ data: Data, filename: String, mimeType: String, to id: DraftID) async throws -> DraftAttachment {
        try await draftStore.addAttachment(data, filename: filename, mimeType: mimeType, to: id)
    }

    func discard(_ id: DraftID) async {
        do {
            try await draftStore.delete(id)
        } catch {
            lastError = "The draft couldn’t be deleted: \(error)"
        }
        await refreshDrafts()
    }

    /// Builds the message from the saved draft, puts it in the outbox and only then removes
    /// the draft. Throws what stops the message from being sent (no recipient, a bad address).
    func send(_ draft: ComposeDraft) async throws {
        guard let outboxActor else {
            throw OutboxError.ownedByAnotherProcess
        }
        guard let account = draft.account else { throw ComposeError.noSender }
        let attachments = try await draftStore.outgoingAttachments(of: draft)
        let message = try MessageComposer.compose(draft, attachments: attachments)
        try await outboxActor.enqueue(message, account: account, draft: draft)
        // Queued and on disk: the draft has done its job. Were this to fail, the draft would
        // stay as well; nothing is sent twice from it, because sending makes a new Message-ID.
        try? await draftStore.delete(draft.id)
        await refreshDrafts()
        Task { await outboxActor.processDue() }
    }

    /// A `mailto:` unsubscribe you previewed (GKM-020): straight into the outbox, no draft kept.
    /// Returns its operation, so the unsubscribe can follow it to sent or failed.
    func queueUnsubscribe(_ draft: ComposeDraft) async throws -> OperationID {
        guard let outboxActor else { throw OutboxError.ownedByAnotherProcess }
        guard let account = draft.account else { throw ComposeError.noSender }
        let entry = try await outboxActor.enqueue(MessageComposer.compose(draft, attachments: []), account: account, draft: nil)
        Task { await outboxActor.processDue() }
        return entry.id
    }

    // MARK: - Outbox intents

    func retry(_ id: OperationID) async {
        guard let outboxActor else { return }
        do {
            try await outboxActor.retry(id)
            await outboxActor.processDue()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Looks for an uncertain message at the provider again.
    func checkAgain(_ id: OperationID) async {
        guard let outboxActor else { return }
        do {
            try await outboxActor.reconcile(id)
        } catch {
            lastError = "\(error)"
        }
    }

    /// The person's decision to send an uncertain message again. The outbox looks in Sent one
    /// more time first and refuses if it is there.
    func sendAgain(_ id: OperationID) async {
        guard let outboxActor else { return }
        do {
            try await outboxActor.sendAgain(id)
            await outboxActor.processDue()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Takes a message out of the outbox and puts it back in Drafts, attachments included.
    @discardableResult
    func cancel(_ id: OperationID) async -> DraftID? {
        guard let outboxActor else { return nil }
        do {
            let (entry, raw) = try await outboxActor.cancel(id)
            let parsed = MIMEParser.parse(raw)
            let attachments = parsed.attachments.map {
                OutgoingAttachment(filename: $0.filename ?? "attachment", mimeType: $0.mimeType, data: $0.body)
            }
            var draft = entry.draft ?? ComposeDraft(account: entry.account, subject: parsed.subject ?? "",
                                                    body: parsed.textBody ?? "")
            draft.id = DraftID()
            draft.revision = 0
            draft.attachments = []
            return try await create(draft, attachments: attachments)
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    // MARK: - Internals

    private func create(_ draft: ComposeDraft, attachments: [OutgoingAttachment]) async throws -> DraftID {
        var draft = draft
        for attachment in attachments {
            draft.attachments.append(try await draftStore.addAttachment(
                attachment.data, filename: attachment.filename, mimeType: attachment.mimeType, to: draft.id))
        }
        let saved = try await draftStore.save(draft).draft
        await refreshDrafts()
        return saved.id
    }

    private static func addresses(of account: MailAccountID, in identities: [SendingIdentity]) -> [MailAddress] {
        identities.filter { $0.account == account }.map(\.address)
    }
}
