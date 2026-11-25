import Foundation
import MailClassifier
import MailCore
import MailProvider
import MailStore
import MailSync

/// What the list shows under "On the server" while searching (GKM-041, MAIL-081): mail at the
/// provider that matches and is not downloaded.
enum ServerSearchState: Equatable {
    /// Nothing to show: not searching, no words to look for, or no account leaves mail at the
    /// provider (all of it is here).
    case off
    /// The search uses something only this device knows, so it can't go to the server.
    case unavailable(String)
    case searching
    /// No connection: nothing was asked; it searches once the account is connected again.
    case offline
    /// The newest matches (at most ``ServerSearcher/defaultLimit`` per account) and how many
    /// match in all.
    case found([ServerSearchHit], total: Int)
    case failed(String)

    var hits: [ServerSearchHit] {
        if case .found(let hits, _) = self { return hits }
        return []
    }

    /// True when the list shows the section.
    var isShown: Bool { self != .off }

    /// The line under the heading; nil when the results say it all.
    var note: String? {
        switch self {
        case .off: nil
        case .unavailable(let reason): reason
        case .searching: "Searching the server…"
        case .offline: "You’re offline. Older mail on the server is searched when you’re connected again."
        case .found(let hits, let total):
            if hits.isEmpty { "No older mail on the server matches." }
            else if total > hits.count { "The newest \(hits.count.formatted()) of \(total.formatted()). Add words to find others." }
            else { nil }
        case .failed(let reason): reason
        }
    }
}

/// The part of a search the provider can run, and where (GKM-041).
struct ServerQuery: Equatable {
    var criteria: RemoteSearchCriteria
    var account: MailAccountID?
    /// One folder (`in:` or the folder chip or selection); every folder with mail left out
    /// otherwise.
    var mailbox: String?
    /// Why this search can't go to the server; nil when it can.
    var unavailable: String?

    /// The provider's half of `query`. Nil without words or people to look for: the server
    /// would otherwise list whole folders. `explicitCategory` is a category the person asked
    /// for (chip or `category:`); the category view being searched in is not one, since mail
    /// that is not downloaded has no category yet.
    static func make(_ query: SearchQuery, explicitCategory: MailCategory?) -> ServerQuery? {
        let criteria = RemoteSearchCriteria(
            terms: SearchQuery.searchTerms(query.text),
            participants: SearchQuery.searchTerms(query.participant ?? ""),
            receivedOnOrAfter: query.after, receivedBefore: query.before,
            unreadOnly: query.unreadOnly, flaggedOnly: query.flaggedOnly)
        guard !criteria.hasNoText else { return nil }
        var server = ServerQuery(criteria: criteria, account: query.account, mailbox: query.mailbox)
        if query.space != nil {
            server.unavailable = "Spaces are kept on \(DeviceWords.this), so mail on the server can’t be searched in one."
        } else if explicitCategory != nil {
            server.unavailable = "Categories are worked out on \(DeviceWords.this), so mail on the server can’t be searched by category."
        } else if query.hasAttachment {
            server.unavailable = "Mail on the server can’t be searched for attachments."
        }
        return server
    }
}

extension ServerSearchHit {
    /// The sender as the list shows it.
    var senderLine: String { sender ?? "Unknown sender" }
    var subjectLine: String { subject?.isEmpty == false ? subject! : "(No subject)" }
    var dateLine: String { receivedAt.map { MessageDate.short($0) } ?? "" }
    /// Where it is and that it is not here yet.
    var whereLine: String { "\(folderName) · not downloaded" }

    var accessibilityText: String {
        [isUnread ? "Unread" : nil, isFlagged ? "Flagged" : nil, "From \(senderLine)", subjectLine, dateLine,
         "On the server in \(folderName), not downloaded"].compactMap { $0 }.joined(separator: ", ")
    }
}
