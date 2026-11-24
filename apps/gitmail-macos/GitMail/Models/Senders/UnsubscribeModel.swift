import Foundation
import MailClassifier
import MailCompose
import MailCore
import MailOutbox
import MailStore
import MailUnsubscribe
import Observation

/// Unsubscribe (GKM-020; ThreatModel §9; MAIL-056, MAIL-057). Offered only for a legitimate list,
/// judged from the stored headers of its newest message; nothing is fetched to decide. The one
/// network request — an RFC 8058 one-click POST — is sent only when you approve it; a `mailto:`
/// unsubscribe is a message you see first and that goes through the outbox; anything else you
/// finish yourself in the browser, with a warning. Every request is tracked: requested, pending
/// (the list accepted it), then confirmed when its mail stops or failed when it doesn't.
@MainActor
@Observable
final class UnsubscribeModel {
    /// What can be done for one sender or list.
    struct Option: Equatable {
        var assessment: UnsubscribeAssessment
        var source: SenderListHeaders?
    }

    private(set) var requests: [UnsubscribeRequest] = []
    /// What the last request could not do, for an alert.
    var notice: String?
    /// Which endpoints may be contacted. Always `.standard` in the app; tests allow their local server.
    @ObservationIgnored var policy: EndpointPolicy = .standard
    /// Drafts and the outbox, for mailto unsubscribes; set once the store is open.
    @ObservationIgnored weak var sending: MailSending?
    /// The account's own address, for the From of a mailto unsubscribe.
    @ObservationIgnored var accountAddresses: @MainActor (MailAccountID) -> [MailAddress] = { _ in [] }
    /// The one-click request in flight, for tests.
    @ObservationIgnored private(set) var inFlight: Task<UnsubscribeRequest?, Never>?
    @ObservationIgnored private var store: MailStore?

    func attach(_ store: MailStore) {
        self.store = store
        requests = []
    }

    /// The newest request for a sender or list.
    func request(for sender: SenderSummary) -> UnsubscribeRequest? {
        requests.last { $0.account == sender.account && $0.scope == sender.scope }
    }

    // MARK: Loading

    /// Reads the requests, moves mailto requests on with their outbox state, and reviews the
    /// pending ones against the mail that arrived since.
    func refresh() async {
        guard let store else { return }
        do {
            for request in try await store.unsubscribeRequests() where request.state == .requested && request.method == "mailto" {
                guard let operation = request.outboxOperation,
                      let entry = sending?.outbox.first(where: { $0.id.rawValue == operation }) else { continue }
                var updated = request
                switch entry.state {
                case .sent:
                    updated.state = .pending
                    updated.detail = "The unsubscribe message was sent. Waiting to see if mail stops."
                case .failed:
                    updated.state = .failed
                    updated.detail = "The unsubscribe message couldn’t be sent. See the Outbox."
                case .queued, .sending, .uncertain:
                    continue
                }
                try await store.saveUnsubscribeRequest(updated)
            }
            try await store.reviewUnsubscribeRequests()
            requests = try await store.unsubscribeRequests()
        } catch {
            notice = String(describing: error)
        }
    }

    /// What may be offered for this sender or list, from the stored headers of its newest
    /// message. Reads files only.
    func option(for sender: SenderSummary) async -> Option {
        guard let store else { return Option(assessment: UnsubscribeAssessment(outcome: .refused(.noHeader), notes: []), source: nil) }
        do {
            let source = try await store.listHeaders(of: sender.scope, account: sender.account)
            let verdict = source?.verdict
            let assessment = UnsubscribeAssessor.assess(headers: source?.headers ?? [:],
                                                        risk: verdict?.classification.risk ?? .none,
                                                        reasons: verdict?.classification.reasons ?? [],
                                                        senderAddress: verdict?.fromAddress, policy: policy)
            return Option(assessment: assessment, source: source)
        } catch {
            notice = String(describing: error)
            return Option(assessment: UnsubscribeAssessment(outcome: .refused(.noHeader), notes: []), source: nil)
        }
    }

    // MARK: One-click (RFC 8058)

    /// Sends the one-click request you approved for `url`. The headers are checked again first:
    /// if the newest message no longer offers exactly this URL, nothing is sent.
    @discardableResult
    func approveOneClick(_ url: URL, for sender: SenderSummary) async -> UnsubscribeRequest? {
        guard let store else { return nil }
        let task = Task { () -> UnsubscribeRequest? in
            guard case .oneClick(let current)? = await option(for: sender).assessment.method, current == url else {
                notice = "This list’s unsubscribe link changed or is no longer offered. Nothing was sent."
                return nil
            }
            var request = UnsubscribeRequest(account: sender.account, scope: sender.scope, method: "one-click", target: url.absoluteString,
                                             detail: "Sending the request…")
            do {
                try await store.saveUnsubscribeRequest(request)
                let result = await OneClickUnsubscriber(policy: policy).unsubscribe(url)
                (request.state, request.detail) = Self.describe(result)
                try await store.saveUnsubscribeRequest(request)
            } catch {
                notice = String(describing: error)
            }
            await refresh()
            return request
        }
        inFlight = task
        return await task.value
    }

    static func describe(_ result: OneClickResult) -> (UnsubscribeRequest.State, String) {
        switch result {
        case .accepted(let status):
            (.pending, "The list accepted the request (\(status)). That isn’t proof yet: we’ll see if mail stops.")
        case .rejected(let status):
            (.failed, "The list refused the request (\(status)). Try its own page, or mute it here.")
        case .redirectRefused(_, let host):
            (.failed, "The list tried to send the request elsewhere\(host.map { " (\($0))" } ?? ""). It wasn’t followed. Mute it here instead.")
        case .refused(let problem):
            (.failed, "Not sent. \(problem.explanation)")
        case .failed(let message):
            (.failed, "The request couldn’t be sent: \(message)")
        }
    }

    // MARK: mailto

    /// The unsubscribe message, to show before sending: from the address the list writes to.
    func mailtoDraft(address: String, subject: String, body: String, for sender: SenderSummary, source: SenderListHeaders?) -> ComposeDraft {
        let own = accountAddresses(sender.account)
        let from = source?.recipients.first { recipient in own.contains { $0.address.lowercased() == recipient.address.lowercased() } }
            ?? own.first
        return ComposeDraft(account: sender.account, from: from, to: [MailAddress(name: nil, address: address)], subject: subject,
                            body: body.isEmpty ? "unsubscribe" : body)
    }

    /// Puts the previewed message in the outbox and records the request.
    func sendMailto(_ draft: ComposeDraft, for sender: SenderSummary) async {
        guard let store, let sending else {
            notice = "Sending isn’t available yet."
            return
        }
        do {
            let operation = try await sending.queueUnsubscribe(draft)
            let request = UnsubscribeRequest(account: sender.account, scope: sender.scope, method: "mailto",
                                             target: draft.to.first?.address ?? "", detail: "The unsubscribe message is in the Outbox.",
                                             outboxOperation: operation.rawValue)
            try await store.saveUnsubscribeRequest(request)
        } catch {
            notice = String(describing: error)
        }
        await refresh()
    }

    // MARK: Manual and your own word

    /// You chose to finish it on the list's page in your browser.
    func openedManually(_ url: URL, for sender: SenderSummary) async {
        guard let store else { return }
        let request = UnsubscribeRequest(account: sender.account, scope: sender.scope, method: "manual", target: url.absoluteString,
                                         state: .pending, detail: "Opened the list’s page in your browser. Waiting to see if mail stops.")
        do { try await store.saveUnsubscribeRequest(request) } catch { notice = String(describing: error) }
        await refresh()
    }

    /// "It stopped" / "Still getting mail".
    func mark(_ request: UnsubscribeRequest, confirmed: Bool) async {
        guard let store else { return }
        var request = request
        request.state = confirmed ? .confirmed : .failed
        request.detail = confirmed ? "You said mail from this list stopped." : "You said mail from this list still arrives."
        do { try await store.saveUnsubscribeRequest(request) } catch { notice = String(describing: error) }
        await refresh()
    }
}

extension UnsubscribeRequest.State {
    var title: String {
        switch self {
        case .requested: "Requested"
        case .pending: "Pending"
        case .confirmed: "Unsubscribed"
        case .failed: "Didn’t Work"
        }
    }
}

extension UnsubscribeAssessment.Refusal {
    /// Why there is no Unsubscribe button, in words.
    var explanation: String {
        switch self {
        case .risky(.phishing): "This looks like phishing. Unsubscribing would tell the sender your address works. Report it instead."
        case .risky: "This looks like junk. Unsubscribing would tell the sender your address works. Report it as junk, or mute it."
        case .doubtfulSender: "The sender may not be who it says it is, so unsubscribing isn’t offered. Report it as junk, or mute it."
        case .noHeader: "This sender doesn’t offer a standard unsubscribe. You can mute it here."
        case .noListContext: "This isn’t clearly a mailing list, so unsubscribing isn’t offered. You can mute it here."
        case .nothingUsable(let problems):
            "The unsubscribe link isn’t safe to use: " + Set(problems).map(\.explanation).sorted().joined(separator: " ")
        }
    }
}
