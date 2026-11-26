import Foundation
import MailProvider
import MailStore

/// Looks for a stored message without a Message-ID in the folders that still have mail not
/// downloaded here, before its deletion at the provider is confirmed (GKM-043, MAIL-104).
///
/// The provider is asked by what a move keeps: the sender (IMAP `FROM`) and the day the message
/// was received (INTERNALDATE, which COPY and MOVE keep) or dated (its Date header), a day either
/// side, since servers compare days in their own zone. A hit is taken for the message when its
/// size (RFC822.SIZE) is the stored size, or when its header has every field of the stored
/// header (names in any case, values unfolded). Not byte for byte: servers differ in what they
/// return (GreenMail leaves out the header's closing empty line and reports a moved message's
/// size as its body's), add fields of their own, or refold lines, and every such difference must
/// fall on the side of "still there". The answer is `false` (not there) only when every search
/// came back and no hit can be the message; when a hit cannot be checked (gone meanwhile, no
/// header, too many to compare by header) or a folder changed under the search, it is `nil`:
/// not sure, so the deletion is not confirmed. A move is never taken for a deletion.
struct DeletionProbe {
    /// The stored message's size at the provider (RFC822.SIZE).
    var size: Int
    /// The stored header's fields, normalized (``fields(of:)``).
    var fields: Set<String>
    var sender: String?
    var received: Date
    var dated: Date?

    /// Most hits whose header is fetched to compare; more than that is not a proof of absence.
    static let headerChecks = 20
    /// UIDs per summary fetch.
    static let summaryBatch = 500

    init(size: Int, header: Data, sender: String?, received: Date, dated: Date?) {
        self.size = size
        self.fields = Self.fields(of: header)
        self.sender = sender
        self.received = received
        self.dated = dated
    }

    /// The probe for a stored message: its front matter and the header of its `.eml` (a partial
    /// message's skeleton starts with the original header too).
    init(_ stored: StoredMessage) throws {
        let eml = try Data(contentsOf: stored.emlURL)
        self.init(size: stored.front.emlSize, header: eml, sender: stored.front.from.first?.address,
                  received: stored.front.received, dated: stored.front.date)
    }

    /// Whether one of `folders` has the message: `true` found, `false` not there, `nil` not sure.
    func find(in folders: [String], _ session: any MailboxSession) async throws -> Bool? {
        let senders = sender.map { [$0] } ?? []
        var searches = [Self.days(around: received) { RemoteSearchCriteria(receivedOnOrAfter: $0, receivedBefore: $1, senders: senders) }]
        if let dated {
            searches.append(Self.days(around: dated) { RemoteSearchCriteria(senders: senders, sentOnOrAfter: $0, sentBefore: $1) })
        }
        for folder in folders {
            do {
                var uids = Set<UInt32>()
                var uidValidity: UInt32?
                for criteria in searches {
                    let listing = try await session.search(criteria, in: folder)
                    guard uidValidity == nil || uidValidity == listing.status.uidValidity else { return nil }
                    uidValidity = listing.status.uidValidity
                    uids.formUnion(listing.uids)
                }
                guard let uidValidity, !uids.isEmpty else { continue }
                switch try await check(uids.sorted().map { RemoteMessageID(folder: folder, uidValidity: uidValidity, uid: $0) }, session) {
                case true?: return true
                case nil: return nil
                case false?: continue
                }
            } catch MailProviderError.folderNotFound {
                return nil // gone since the listing: the message may have gone with it
            }
        }
        return false
    }

    /// Whether one of these hits is the message: by size first (one command for all), then by
    /// header for the rest.
    private func check(_ hits: [RemoteMessageID], _ session: any MailboxSession) async throws -> Bool? {
        var summaries: [RemoteMessageSummary] = []
        for start in stride(from: 0, to: hits.count, by: Self.summaryBatch) {
            summaries += try await session.summaries(of: Array(hits[start..<min(start + Self.summaryBatch, hits.count)]))
        }
        // A hit gone between the search and the fetch cannot be ruled out.
        guard summaries.count == hits.count else { return nil }
        if summaries.contains(where: { $0.size == size }) { return true }
        guard hits.count <= Self.headerChecks else { return nil }
        for hit in hits {
            do {
                // No header back cannot rule the hit out.
                guard let header = try await session.fetchSections(["HEADER"], of: hit)["HEADER"] else { return nil }
                if fields.isSubset(of: Self.fields(of: header)) { return true }
            } catch MailProviderError.messageNotFound {
                return nil
            }
        }
        return false
    }

    /// A search for the calendar days from the one before `date` to the one after it.
    private static func days(around date: Date, _ make: (Date, Date) -> RemoteSearchCriteria) -> RemoteSearchCriteria {
        make(date.addingTimeInterval(-86_400), date.addingTimeInterval(2 * 86_400))
    }

    /// The header fields of a raw message or header, up to the first empty line: each as its
    /// lowercased name and its value unfolded, runs of white space made one space.
    static func fields(of raw: Data) -> Set<String> {
        var lines: [String] = []
        // By bytes: as a String, CR LF is one Character and would not split at LF.
        for line in raw.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let bytes = line.last == 0x0D ? line.dropLast() : line
            if bytes.isEmpty { break }
            let text = String(decoding: bytes, as: UTF8.self)
            if let first = bytes.first, first == 0x20 || first == 0x09, !lines.isEmpty {
                lines[lines.count - 1] += " " + text
            } else {
                lines.append(text)
            }
        }
        return Set(lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let value = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() + ": " + value
        })
    }
}
