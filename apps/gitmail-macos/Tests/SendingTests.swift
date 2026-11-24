import XCTest
import MailCompose
import MailCore
import MailMIME
import MailOutbox
import MailStore

/// Compose, drafts and the outbox through the app model, against a real store, a real drafts
/// folder and a real outbox journal in a temporary folder. No network: sending itself is
/// proven in GitKittieMailProviders' integration tests.
@MainActor
final class SendingTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let work = MailAccountID("work")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-send-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Ada Lovelace", address: "ada@example.com"))
        try await store.ingest(Data("""
        From: Bo <bo@example.net>\r
        To: Ada Lovelace <ada@example.com>, Cy <cy@example.org>\r
        Cc: ADA@example.com, Di <di@example.org>\r
        Reply-To: Bo at home <bo@home.example.net>\r
        Subject: Dinner on Friday\r
        Date: Mon, 23 Nov 2026 18:00:00 +0000\r
        Message-ID: <dinner-1@example.net>\r
        References: <plan-0@example.org>\r
        \r
        Shall we?\r

        """.utf8), account: work)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openModel() async throws -> (AppModel, MailSending) {
        let model = AppModel(locations: locations)
        await model.open()
        XCTAssertEqual(model.phase, .ready)
        let sending = try XCTUnwrap(model.sending)
        sending.pumpInterval = .seconds(3600)
        return (model, sending)
    }

    private func compose(_ id: DraftID, _ model: AppModel, _ sending: MailSending) async -> ComposeModel {
        let compose = ComposeModel(draftID: id, sending: sending)
        compose.autosaveInterval = .milliseconds(1)
        await compose.load(accounts: model.accounts)
        return compose
    }

    func testReplyAllFromTheReaderMakesADraftWithTheRightHeaders() async throws {
        let (model, sending) = try await openModel()
        let id = try XCTUnwrap(model.messages.first?.id)
        await model.selectMessage(id)
        XCTAssertTrue(model.canAnswer)

        let draftIDValue = await model.compose(.replyAll)

        let draftID = try XCTUnwrap(draftIDValue)
        let draftValue = await sending.draft(draftID)
        let draft = try XCTUnwrap(draftValue)
        XCTAssertEqual(draft.kind, .replyAll)
        XCTAssertEqual(draft.account, work)
        XCTAssertEqual(draft.from?.address, "ada@example.com")
        XCTAssertEqual(draft.to.map(\.address), ["bo@home.example.net"], "Reply-To is honoured")
        XCTAssertEqual(draft.cc.map(\.address), ["cy@example.org", "di@example.org"], "everyone else once, never me")
        XCTAssertEqual(draft.subject, "Re: Dinner on Friday")
        XCTAssertEqual(draft.inReplyTo, "dinner-1@example.net")
        XCTAssertEqual(draft.references, ["plan-0@example.org", "dinner-1@example.net"])
        XCTAssertEqual(draft.source, id)
        XCTAssertEqual(sending.drafts.map(\.id), [draftID], "it is in Drafts at once")

        let forwardIDValue = await model.compose(.forward)

        let forwardID = try XCTUnwrap(forwardIDValue)
        let forwardValue = await sending.draft(forwardID)
        let forward = try XCTUnwrap(forwardValue)
        XCTAssertEqual(forward.subject, "Fwd: Dinner on Friday")
        XCTAssertEqual(forward.to, [])
        await sending.stop()
    }

    /// GKM-013 acceptance: a crash while writing loses at most a few seconds. What was typed is
    /// on disk once the autosave interval has passed, without closing or sending.
    func testTypingIsOnDiskWithinTheAutosaveInterval() async throws {
        let (model, sending) = try await openModel()
        let idValue = await model.composeNew()
        let id = try XCTUnwrap(idValue)
        let compose = await compose(id, model, sending)
        XCTAssertEqual(compose.phase, .editing)
        XCTAssertEqual(compose.selectedIdentity?.address.address, "ada@example.com", "the account's address by default")

        compose.subject = "Plans"
        compose.body = "First"
        compose.body = "First line"
        XCTAssertEqual(compose.saveState, .unsaved)
        await compose.pendingAutosave?.value
        XCTAssertEqual(compose.saveState, .saved)

        // A relaunch (a new store over the same folder) finds the text.
        let relaunched = try DraftStore(locations: locations)
        let onDisk = try await relaunched.draft(id)
        XCTAssertEqual(onDisk?.body, "First line")
        XCTAssertEqual(onDisk?.subject, "Plans")
        XCTAssertEqual(onDisk?.revision, 2, "created, then one save for the burst of edits")
        await sending.stop()
    }

    func testRecipientsBecomeTokensAndBadOnesBlockSending() async throws {
        let (model, sending) = try await openModel()
        let idValue = await model.composeNew()
        let id = try XCTUnwrap(idValue)
        let compose = await compose(id, model, sending)

        compose.pending[.to] = "Kim <kim@example.org>, not-an-address, kim@EXAMPLE.org"
        compose.commitPending(.to)
        XCTAssertEqual(compose.recipients(.to), [MailAddress(name: "Kim", address: "kim@example.org")])
        XCTAssertEqual(compose.pending[.to], "not-an-address")

        let sent = await compose.send()
        XCTAssertFalse(sent)
        XCTAssertEqual(compose.notice, "“not-an-address” is not an email address.")
        XCTAssertEqual(sending.outbox, [])
        await sending.stop()
    }

    /// Send puts the exact message in the outbox journal and only then removes the draft. With
    /// no sending settings for the account yet (GKM-010), it waits visibly and sends nothing.
    func testSendQueuesTheMessageAndCancelPutsTheDraftBack() async throws {
        let (model, sending) = try await openModel()
        let idValue = await model.composeNew()
        let id = try XCTUnwrap(idValue)
        let compose = await compose(id, model, sending)
        compose.pending[.to] = "kim@example.org"
        compose.commitPending(.to)
        compose.showsCcAndBcc = true
        compose.pending[.bcc] = "hidden@example.com"
        compose.commitPending(.bcc)
        compose.subject = "Plans"
        compose.body = "Hello **Kim**."
        await compose.attach(Data("plan".utf8), filename: "plan.txt", mimeType: "text/plain")

        let queued = await compose.send()
        XCTAssertTrue(queued, compose.notice ?? "")
        XCTAssertEqual(compose.phase, .sent)
        let gone = await sending.draft(id)
        XCTAssertNil(gone, "the draft is removed once the message is in the outbox")

        await waitForOutbox(sending) { !$0.isEmpty }
        let entry = try XCTUnwrap(sending.outbox.first)
        XCTAssertEqual(entry.state, .queued)
        XCTAssertEqual(entry.attempts, 0)
        XCTAssertEqual(entry.recipients, ["kim@example.org", "hidden@example.com"])
        XCTAssertEqual(entry.visibleRecipients, ["kim@example.org"])
        XCTAssertEqual(sending.pending.map(\.id), [entry.id])

        let journal = locations.outboxFolder.appendingPathComponent(entry.id.rawValue)
        let raw = try Data(contentsOf: journal.appendingPathComponent("message.eml"))
        let message = MIMEParser.parse(raw)
        XCTAssertEqual(message.messageID, entry.messageID)
        XCTAssertNil(message.headers["Bcc"])
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("hidden@example.com"))
        XCTAssertEqual(message.attachments.map(\.filename), ["plan.txt"])
        XCTAssertTrue(message.htmlBody?.contains("<strong>Kim</strong>") == true)

        // Cancel: back to Drafts, attachment included, as a new draft.
        let restoredValue = await sending.cancel(entry.id)
        let restored = try XCTUnwrap(restoredValue)
        let draftValue = await sending.draft(restored)
        let draft = try XCTUnwrap(draftValue)
        XCTAssertEqual(draft.subject, "Plans")
        XCTAssertEqual(draft.bcc.map(\.address), ["hidden@example.com"])
        XCTAssertEqual(draft.attachments.map(\.filename), ["plan.txt"])
        await waitForOutbox(sending) { $0.isEmpty }
        await sending.stop()
    }

    func testABlankDraftIsRemovedWhenItsWindowCloses() async throws {
        let (model, sending) = try await openModel()
        let idValue = await model.composeNew()
        let id = try XCTUnwrap(idValue)
        let compose = await compose(id, model, sending)
        await compose.close()
        let draft = await sending.draft(id)
        XCTAssertNil(draft)
        XCTAssertEqual(sending.drafts, [])
        await sending.stop()
    }

    func testOnlyOneCopyOfTheAppOwnsTheOutbox() async throws {
        let (_, sending) = try await openModel()
        let second = AppModel(locations: locations)
        await second.open()
        XCTAssertEqual(second.sending?.outboxAvailability,
                       .unavailable("Another copy of GitKittie Mail is sending from this Mac."))
        await sending.stop()
        await second.sending?.stop()
    }

    private func waitForOutbox(_ sending: MailSending, until condition: ([OutboxEntry]) -> Bool) async {
        for _ in 0..<200 where !condition(sending.outbox) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(sending.outbox), "outbox did not reach the expected state: \(sending.outbox)")
    }
}
