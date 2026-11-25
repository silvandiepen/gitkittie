import Foundation
import MailProvider
import NIOCore
import NIOIMAP

// Searching the provider for mail that is not downloaded (GKM-041, MAIL-081). One UID SEARCH
// per folder; the caller fetches summaries for as many of the UIDs as it shows.
extension IMAPSession {
    public func search(_ criteria: RemoteSearchCriteria, in folder: String) async throws -> FolderListing {
        let state = try await select(folder, refresh: true)
        guard state.status.messageCount > 0 else { return FolderListing(status: state.status, uids: []) }
        let key = Self.searchKey(criteria)
        // US-ASCII needs no CHARSET; anything else is sent as UTF-8, which servers must accept
        // with CHARSET (RFC 9051) and nearly all IMAP4rev1 servers do.
        let words = criteria.terms + criteria.participants
        let utf8: CharacterSetName = "UTF-8"
        let charset = words.allSatisfy { $0.utf8.allSatisfy { $0 < 0x80 } } ? nil : utf8
        let result = try await wire.run(.uidSearch(key: key, charset: charset),
                                        logAs: "UID SEARCH (\(criteria.terms.count) words, \(criteria.participants.count) people) in \(folder)")
        try Self.check(result, "UID SEARCH")
        var uids: [UInt32] = []
        for case .mailboxData(.search(let found, _)) in result.untagged {
            uids += found.map(\.rawValue)
        }
        _ = wire.takeUnsolicited()
        return FolderListing(status: state.status, uids: Array(Set(uids)).sorted())
    }

    /// Every condition of `criteria`, ANDed: a word in the subject, the sender or the text; a
    /// person in From, To or Cc (envelope or header text); the received day; unread; flagged. Never empty (`ALL`).
    static func searchKey(_ criteria: RemoteSearchCriteria) -> SearchKey {
        var keys: [SearchKey] = []
        for term in criteria.terms {
            let value = ByteBuffer(string: term)
            keys.append(.or(.subject(value), .or(.from(value), .text(value))))
        }
        for person in criteria.participants {
            let value = ByteBuffer(string: person)
            // FROM/TO/CC search the parsed envelope, by RFC 3501 a substring of name or address;
            // some servers match them against the whole address only (GreenMail 2.1.3 does), so
            // the header's text is searched too (HEADER, a substring by every server's reading).
            func field(_ key: SearchKey, _ name: String) -> SearchKey { .or(key, .header(name, value)) }
            keys.append(.or(field(.from(value), "From"), .or(field(.to(value), "To"), field(.cc(value), "Cc"))))
        }
        if let since = criteria.receivedOnOrAfter { keys.append(.since(calendarDay(since))) }
        if let before = criteria.receivedBefore { keys.append(.before(calendarDay(before))) }
        if criteria.unreadOnly { keys.append(.unseen) }
        if criteria.flaggedOnly { keys.append(.flagged) }
        switch keys.count {
        case 0: return .all
        case 1: return keys[0]
        default: return .and(keys)
        }
    }
}
