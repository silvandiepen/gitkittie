import Foundation
import MailCompose
import MailCore
import MailMIME
import Observation

/// One compose window's state (GKM-013). Every edit marks the draft dirty and schedules a save
/// within ``autosaveInterval``, however fast the typing: a crash loses at most that much.
@MainActor
@Observable
final class ComposeModel {
    enum Field: Hashable, CaseIterable { case to, cc, bcc }

    enum SaveState: Equatable {
        case saved
        case unsaved
        case failed(String)
    }

    enum Phase: Equatable {
        case loading
        case editing
        case sending
        /// Queued in the outbox; the window can close.
        case sent
        case missing
    }

    private(set) var draft: ComposeDraft
    private(set) var phase: Phase = .loading
    private(set) var saveState: SaveState = .saved
    private(set) var identities: [SendingIdentity] = []
    /// A notice for the person: a conflict copy was made, or sending was refused.
    var notice: String?
    /// What is being typed in each address field, not yet a recipient.
    var pending: [Field: String] = [:]
    var showsCcAndBcc = false

    @ObservationIgnored let sending: MailSending
    @ObservationIgnored var autosaveInterval: Duration = .seconds(2)
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// The save the last edit scheduled, if it has not run yet. Awaiting it is how a caller
    /// (or a test) knows the edit is on disk.
    var pendingAutosave: Task<Void, Never>? { autosaveTask }
    /// Saves run one after another, each from the revision the last one wrote.
    @ObservationIgnored private var saveChain: Task<Void, Never>?

    init(draftID: DraftID, sending: MailSending) {
        self.sending = sending
        self.draft = ComposeDraft(id: draftID)
    }

    // MARK: - Loading

    func load(accounts: [MailAccount]) async {
        identities = await sending.identities(accounts: accounts)
        guard let stored = await sending.draft(draft.id) else {
            phase = .missing
            return
        }
        draft = stored
        if draft.from == nil, let first = identities.first {
            draft.from = first.address
            draft.account = first.account
        }
        showsCcAndBcc = !draft.cc.isEmpty || !draft.bcc.isEmpty
        phase = .editing
    }

    // MARK: - Editing

    var subject: String {
        get { draft.subject }
        set { draft.subject = newValue; edited() }
    }

    var body: String {
        get { draft.body }
        set { draft.body = newValue; edited() }
    }

    var selectedIdentity: SendingIdentity? {
        get { identities.first { $0.account == draft.account && $0.address.address.lowercased() == draft.from?.address.lowercased() } }
        set {
            guard let newValue else { return }
            draft.account = newValue.account
            draft.from = newValue.address
            edited()
        }
    }

    func recipients(_ field: Field) -> [MailAddress] {
        switch field {
        case .to: draft.to
        case .cc: draft.cc
        case .bcc: draft.bcc
        }
    }

    /// Turns what was typed into recipients: everything that parses as an address becomes a
    /// token; what does not stays in the field to be fixed.
    func commitPending(_ field: Field) {
        let text = pending[field, default: ""]
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let parsed = AddressParser.parseList(text)
        let valid = parsed.filter { MessageComposer.isValidAddress($0.address) }
        let invalid = AddressParser.splitTopLevelForDisplay(text).filter { item in
            !valid.contains { item.localizedCaseInsensitiveContains($0.address) }
        }
        add(valid, to: field)
        pending[field] = invalid.joined(separator: ", ")
    }

    func remove(_ address: MailAddress, from field: Field) {
        set(recipients(field).filter { $0 != address }, for: field)
    }

    func isValid(_ address: MailAddress) -> Bool { MessageComposer.isValidAddress(address.address) }

    func attach(_ data: Data, filename: String, mimeType: String) async {
        do {
            let attachment = try await sending.addAttachment(data, filename: filename, mimeType: mimeType, to: draft.id)
            if !draft.attachments.contains(attachment) { draft.attachments.append(attachment) }
            edited()
        } catch {
            notice = "“\(filename)” couldn’t be attached: \(error)"
        }
    }

    func removeAttachment(_ attachment: DraftAttachment) {
        draft.attachments.removeAll { $0 == attachment }
        edited()
    }

    /// Something changed: save within ``autosaveInterval``. Further edits in that time ride
    /// along with the same save rather than pushing it back.
    func edited() {
        saveState = .unsaved
        guard autosaveTask == nil else { return }
        let interval = autosaveInterval
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Writes the draft now (window closing, before sending, after the autosave delay).
    func saveNow() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        let previous = saveChain
        let save = Task { [weak self] in
            await previous?.value
            await self?.performSave()
        }
        saveChain = save
        await save.value
    }

    private func performSave() async {
        guard phase == .editing || phase == .sending else { return }
        do {
            switch try await sending.save(draft) {
            case .saved(let saved), .unchanged(let saved):
                draft.revision = saved.revision
                draft.updatedAt = saved.updatedAt
                draft.savedBy = saved.savedBy
            case .conflict(let copy):
                // This window now edits the copy; the other version stays as it was.
                draft = copy
                notice = "This draft was changed in another window or on another device. Your version is kept as a separate draft."
            }
            if autosaveTask == nil { saveState = .saved }
        } catch {
            saveState = .failed("\(error)")
        }
    }

    /// Ends editing: a draft that was never given any content is removed again.
    func close() async {
        if phase == .editing, draft.isBlank, pendingIsEmpty {
            autosaveTask?.cancel()
            autosaveTask = nil
            await sending.discard(draft.id)
            phase = .missing
            return
        }
        await saveNow()
    }

    func discard() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await sending.discard(draft.id)
        phase = .missing
    }

    /// Queues the message. True when it is in the outbox and the window may close.
    @discardableResult
    func send() async -> Bool {
        for field in Field.allCases { commitPending(field) }
        if let leftover = Field.allCases.lazy.compactMap({ self.pending[$0] }).first(where: { !$0.isEmpty }) {
            notice = "“\(leftover)” is not an email address."
            return false
        }
        phase = .sending
        await saveNow()
        do {
            try await sending.send(draft)
            phase = .sent
            return true
        } catch {
            phase = .editing
            notice = "\(error)"
            return false
        }
    }

    // MARK: - Internals

    private var pendingIsEmpty: Bool {
        pending.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func add(_ addresses: [MailAddress], to field: Field) {
        var current = recipients(field)
        for address in addresses where !current.contains(where: { $0.address.lowercased() == address.address.lowercased() }) {
            current.append(address)
        }
        set(current, for: field)
    }

    private func set(_ addresses: [MailAddress], for field: Field) {
        switch field {
        case .to: draft.to = addresses
        case .cc: draft.cc = addresses
        case .bcc: draft.bcc = addresses
        }
        edited()
    }
}

extension AddressParser {
    /// The items of a typed list, as typed, for leaving the ones that are not addresses in the
    /// field.
    static func splitTopLevelForDisplay(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
