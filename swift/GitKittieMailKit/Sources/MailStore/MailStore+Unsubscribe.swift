import Foundation
import MailCore

// What became of your unsubscribe requests (GKM-020; MAIL-057). A request sent is not proof: a
// list that accepted it is pending until its mail stops, and failed if mail keeps coming. User
// data, next to the corrections and rules: `<device folder>/metadata/unsubscribes.json`.

public struct UnsubscribeRequest: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// You approved it; it is being sent (a one-click POST, or a message in the outbox).
        case requested
        /// The list accepted it (a 2xx answer, or the message was sent). Waiting for mail to stop.
        case pending
        /// Mail stopped: nothing from the list for `quietPeriod` after the request, or you said so.
        case confirmed
        /// It was refused, could not be sent, or mail still arrives after `gracePeriod`.
        case failed
    }

    public var id: String
    public var account: MailAccountID
    public var scope: SenderScope
    /// "one-click", "mailto" or "manual".
    public var method: String
    /// The URL or address it went to.
    public var target: String
    public var state: State
    /// What happened, in words ("The list accepted the request (202).").
    public var detail: String
    /// The outbox operation of a mailto request.
    public var outboxOperation: String?
    public var requestedAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), account: MailAccountID, scope: SenderScope, method: String, target: String,
                state: State = .requested, detail: String = "", outboxOperation: String? = nil, requestedAt: Date = Date()) {
        self.id = id
        self.account = account
        self.scope = scope
        self.method = method
        self.target = target
        self.state = state
        self.detail = detail
        self.outboxOperation = outboxOperation
        self.requestedAt = requestedAt
        self.updatedAt = requestedAt
    }

    /// Lists may take two days to process a request (the large mailbox providers' own rule).
    public static let gracePeriod: TimeInterval = 2 * 86_400
    /// Two weeks without mail after the request counts as confirmed.
    public static let quietPeriod: TimeInterval = 14 * 86_400
}

struct UnsubscribeLedger: Codable, Equatable {
    static let version = 1
    var version = Self.version
    var requests: [UnsubscribeRequest] = []

    static func url(in deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("metadata", isDirectory: true).appendingPathComponent("unsubscribes.json")
    }
}

extension MailStore {
    /// Your unsubscribe requests, oldest first.
    public func unsubscribeRequests() throws -> [UnsubscribeRequest] { try unsubscribeLedger().requests }

    /// Records a new request or a change to one.
    public func saveUnsubscribeRequest(_ request: UnsubscribeRequest) throws {
        var ledger = try unsubscribeLedger()
        var request = request
        request.updatedAt = Date()
        if let index = ledger.requests.firstIndex(where: { $0.id == request.id }) {
            ledger.requests[index] = request
        } else {
            ledger.requests.append(request)
        }
        try writer.write(JSONCoding.prettyEncoder.encode(ledger), to: UnsubscribeLedger.url(in: locations.deviceFolder))
    }

    /// Looks at the mail that arrived since each pending request: mail dated after the grace
    /// period means it failed; none for the quiet period means it worked. Returns the requests
    /// that changed.
    @discardableResult
    public func reviewUnsubscribeRequests(now: Date = Date()) throws -> [UnsubscribeRequest] {
        var changed: [UnsubscribeRequest] = []
        for var request in try unsubscribeRequests() where request.state == .pending {
            let newest = try index.members(of: request.scope, account: request.account).first?.date
            if let newest, newest > request.requestedAt.addingTimeInterval(UnsubscribeRequest.gracePeriod) {
                request.state = .failed
                request.detail = "Mail from this list still arrives, more than two days after you unsubscribed."
            } else if now.timeIntervalSince(request.requestedAt) >= UnsubscribeRequest.quietPeriod {
                request.state = .confirmed
                request.detail = "No mail from this list in the two weeks since you unsubscribed."
            } else {
                continue
            }
            try saveUnsubscribeRequest(request)
            changed.append(request)
        }
        return changed
    }

    private func unsubscribeLedger() throws -> UnsubscribeLedger {
        let url = UnsubscribeLedger.url(in: locations.deviceFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return UnsubscribeLedger() }
        let ledger = try JSONCoding.decoder.decode(UnsubscribeLedger.self, from: Data(contentsOf: url))
        guard ledger.version <= UnsubscribeLedger.version else { throw MailStoreError.unsupportedMetadataVersion(ledger.version) }
        return ledger
    }
}
