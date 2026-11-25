import Foundation
import MailProvider
import NIOCore
import NIOIMAP

// Batched reads for the sync coordinator (GKM-011): one command per call, the caller picks the
// batch size. UIDs go on the wire as a compact UID set (ranges), so a batch of 500 contiguous
// UIDs is "1:500", not 500 numbers.
extension IMAPSession {
    /// Summaries per `UID FETCH` when a caller does not batch itself (``changes(in:since:)``).
    static let summaryBatchSize = 500

    public var maximumMessageSize: Int { IMAPWire.maximumBodySize }

    public func listing(of folder: String) async throws -> FolderListing {
        let state = try await select(folder, refresh: true)
        guard state.status.messageCount > 0 else { return FolderListing(status: state.status, uids: []) }
        let result = try await wire.run(.uidSearch(key: .all), logAs: "UID SEARCH ALL in \(folder)")
        try Self.check(result, "UID SEARCH ALL")
        var uids: [UInt32] = []
        for case .mailboxData(.search(let found, _)) in result.untagged {
            uids += found.map(\.rawValue)
        }
        // A listing describes the folder at this moment; what arrived meanwhile shows up as an
        // EXISTS, which the next listing picks up.
        _ = wire.takeUnsolicited()
        return FolderListing(status: state.status, uids: Array(Set(uids)).sorted())
    }

    public func uids(in folder: String, uidValidity: UInt32, receivedSince day: Date) async throws -> [UInt32] {
        let state = try await select(folder)
        guard state.status.uidValidity == uidValidity else {
            throw MailProviderError.commandFailed("\(folder): UIDVALIDITY changed since it was listed")
        }
        guard state.status.messageCount > 0 else { return [] }
        let result = try await wire.run(.uidSearch(key: .since(Self.calendarDay(day))), logAs: "UID SEARCH SINCE in \(folder)")
        try Self.check(result, "UID SEARCH SINCE")
        var uids: [UInt32] = []
        for case .mailboxData(.search(let found, _)) in result.untagged {
            uids += found.map(\.rawValue)
        }
        _ = wire.takeUnsolicited()
        return Array(Set(uids)).sorted()
    }

    /// The calendar day of `date` in UTC, as IMAP dates are written (SEARCH SINCE has no time).
    static func calendarDay(_ date: Date) -> IMAPCalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        // IMAP days run from 1900 to 2500; a Gregorian month and day are always valid.
        let year = min(max(parts.year ?? 1900, 1900), 2500)
        return IMAPCalendarDay(year: year, month: parts.month ?? 1, day: parts.day ?? 1)!
    }

    public func summaries(of ids: [RemoteMessageID]) async throws -> [RemoteMessageSummary] {
        guard !ids.isEmpty else { return [] }
        let (folder, uids) = try await selectForMessages(ids)
        let result = try await wire.run(
            .uidFetch(.set(Self.uidSet(uids)), [.uid, .flags, .rfc822Size, .internalDate, .envelope], []),
            logAs: "UID FETCH (\(uids.count) summaries) in \(folder)"
        )
        try Self.check(result, "UID FETCH summaries")
        let wanted = Set(uids)
        return result.fetches
            .compactMap { Self.summary(from: $0, folder: folder, uidValidity: ids[0].uidValidity) }
            .filter { wanted.contains($0.id.uid) }
            .sorted { $0.id.uid < $1.id.uid }
    }

    public func fetchMessages(_ ids: [RemoteMessageID]) async throws -> [FetchedMessage] {
        guard !ids.isEmpty else { return [] }
        let (folder, uids) = try await selectForMessages(ids)
        let result = try await wire.run(
            .uidFetch(.set(Self.uidSet(uids)),
                      [.uid, .flags, .rfc822Size, .internalDate, .envelope, .bodySection(peek: true, .complete, nil)], []),
            logAs: "UID FETCH (\(uids.count) × BODY.PEEK[]) in \(folder)"
        )
        try Self.check(result, "UID FETCH bodies")
        let wanted = Set(uids)
        var messages: [FetchedMessage] = []
        for fetch in result.fetches {
            guard let summary = Self.summary(from: fetch, folder: folder, uidValidity: ids[0].uidValidity),
                  wanted.contains(summary.id.uid), let body = fetch.body else { continue }
            messages.append(FetchedMessage(summary: summary, rawMessage: body))
        }
        return messages.sorted { $0.summary.id.uid < $1.summary.id.uid }
    }

    public func flags(of ids: [RemoteMessageID]) async throws -> [RemoteMessageID: MessageFlags] {
        guard !ids.isEmpty else { return [:] }
        let (folder, uids) = try await selectForMessages(ids)
        let result = try await wire.run(.uidFetch(.set(Self.uidSet(uids)), [.uid, .flags], []),
                                        logAs: "UID FETCH (\(uids.count) × FLAGS) in \(folder)")
        try Self.check(result, "UID FETCH FLAGS")
        let wanted = Set(uids)
        var flags: [RemoteMessageID: MessageFlags] = [:]
        for fetch in result.fetches {
            guard let summary = Self.summary(from: fetch, folder: folder, uidValidity: ids[0].uidValidity),
                  wanted.contains(summary.id.uid) else { continue }
            flags[summary.id] = summary.flags
        }
        return flags
    }
}
