import CryptoKit
import XCTest
import MailCore
@testable import MailStore

/// Encrypted archive export and restore (GKM-032, MAIL-128..130): a round trip into a clean
/// folder on "another machine", and every way an archive can be wrong — wrong key, a typo in
/// the key, a changed, moved, dropped or cut record, a changed header, bytes after the end, a
/// path that would escape the folder. Real files in a temporary folder, real CryptoKit; no fakes.
final class EncryptedArchiveTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var destination: URL!
    private let work = MailAccountID("acct-work")
    private let home = MailAccountID("acct-home")
    /// A fixed key, so a test that edits its text is deterministic.
    private let fixedKey = ArchiveRecoveryKey(bytes: Array(0..<16).map { UInt8($0 * 13 + 7) })
    /// Small records, so the small test mailbox spans many of them.
    private let smallChunks = 4 * 1024

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm032-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        destination = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A clean machine: nothing of the original store's folders.
    private var fresh: StoreLocations {
        StoreLocations(mailFolder: root.appendingPathComponent("Other Mac/Mail"), deviceFolder: root.appendingPathComponent("Other Mac/Support/Mail"))
    }

    private let pdf = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }) // spans several 4 KiB records

    /// Two accounts, an attachment, a thread, a space with a rule, a sender rule, a
    /// classification rule and a correction.
    @discardableResult
    private func seed(_ store: MailStore) async throws -> [String: MailMessageID] {
        let connection = MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "imap.example.com", port: 993, security: .implicitTLS, username: "ada"),
            smtp: MailServerSettings(host: "smtp.example.com", port: 587, security: .startTLS, username: "ada@example.com"))
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com", connection: connection))
        try await store.save(MailAccount(id: home, displayName: "Home", address: "ada@example.org"))
        var ids: [String: MailMessageID] = [:]
        ids["quote"] = try await store.ingest(SyntheticMail.withAttachment(subject: "Quote", messageID: "quote@example.net", body: "Quote attached.",
                                                                           fileName: "quote.pdf", attachment: pdf), account: work).id
        ids["invoice"] = try await store.ingest(SyntheticMail.plain(subject: "Invoice 7", messageID: "inv7@example.com", body: "Invoice."),
                                                account: work).id
        ids["reply"] = try await store.ingest(SyntheticMail.plain(from: "Bo Example <bo@example.org>", subject: "Re: Invoice 7",
                                                                  date: "Tue, 24 Nov 2026 12:00:00 +0000", messageID: "re7@example.org",
                                                                  inReplyTo: "inv7@example.com", body: "Paid."), account: work).id
        ids["news"] = try await store.ingest(SyntheticMail.plain(from: "Shop <news@shop.example.com>", subject: "Weekly offers",
                                                                 messageID: "news1@shop.example.com", body: "Offers.",
                                                                 extraHeaders: ["List-Id: Offers <offers.shop.example.com>"]), account: home).id
        let space = try await store.createSpace(name: "Money", icon: "eurosign", color: "green")
        _ = try await store.setRules([SpaceRule(domain: "example.org")], of: space.id)
        _ = try await store.addMessages([ids["quote"]!], to: space.id)
        try await store.setSenderRules([SenderRule(account: home, scope: .sender("news@shop.example.com"), action: .mute)])
        try await store.addRule(.list("offers.shop.example.com"), purpose: .promotion, account: home)
        _ = try await store.correct(ids["invoice"]!, purpose: .transaction)
        return ids
    }

    private func files(under folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let rootPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])! {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(rootPath.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }

    private func write(_ store: MailStore, key: ArchiveRecoveryKey? = nil) async throws -> EncryptedArchiveResult {
        try await store.writeEncryptedArchive(to: destination, name: "Backup", now: Date(timeIntervalSince1970: 1_795_000_000),
                                              recoveryKey: key ?? fixedKey, chunkSize: smallChunks)
    }

    // MARK: Round trip

    /// The acceptance criterion: an encrypted export restores on a clean machine with the
    /// recovery key, as typed by a person, and the store opens it with every message, space,
    /// rule and correction.
    func testArchiveRestoresOnACleanMachineWithTheRecoveryKey() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let result = try await store.writeEncryptedArchive(to: destination, name: "Backup")
        XCTAssertEqual(result.file.lastPathComponent, "Backup.gkmarchive")
        XCTAssertEqual(result.messages, 4)
        XCTAssertEqual(result.attachments, 1)
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(result.partial, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["Backup.gkmarchive"], "no staging file left")

        // Nothing readable in the archive: no subject, address, body or attachment bytes.
        let archived = try Data(contentsOf: result.file)
        for secret in ["Invoice 7", "ada@example.com", "Paid.", "Money", "news@shop.example.com", "imap.example.com"] {
            XCTAssertNil(archived.range(of: Data(secret.utf8)), "“\(secret)” is in the clear")
        }
        XCTAssertNil(archived.range(of: pdf.prefix(64)))

        // The key as a person types it from a printout: lower case, spaces for dashes.
        let typed = try ArchiveRecoveryKey(result.recoveryKey.text.lowercased().replacingOccurrences(of: "-", with: " "))
        let restored = try EncryptedArchive.restore(result.file, recoveryKey: typed, into: fresh)
        XCTAssertEqual(restored.messages, 4)
        XCTAssertEqual(restored.files, result.files)
        XCTAssertEqual(restored.bytes, result.bytes)

        // Every file of the mail folder, byte for byte, and the user metadata.
        XCTAssertEqual(try files(under: fresh.mailFolder), try files(under: locations.mailFolder))
        for file in EncryptedArchive.deviceMetadataFiles {
            let original = locations.deviceFolder.appendingPathComponent("metadata/\(file)")
            guard FileManager.default.fileExists(atPath: original.path) else { continue }
            XCTAssertEqual(try Data(contentsOf: fresh.deviceFolder.appendingPathComponent("metadata/\(file)")), try Data(contentsOf: original), file)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.deviceFolder.appendingPathComponent("index.sqlite").path),
                       "device state is never in the archive")

        // The store opens it: the index is rebuilt and everything is there.
        let other = try await MailStore.open(fresh)
        let messageCount = try await other.messageCount()
        XCTAssertEqual(messageCount, 4)
        for id in ids.values {
            let restoredBytes = try await other.originalData(of: id)
            let originalBytes = try await store.originalData(of: id)
            XCTAssertEqual(restoredBytes, originalBytes)
        }
        let accounts = try await other.accounts()
        XCTAssertEqual(Set(accounts.map(\.id)), [work, home])
        XCTAssertEqual(accounts.first { $0.id == work }?.connection?.imap.host, "imap.example.com", "servers come along, passwords never do")
        let spaces = try await other.spaces()
        let originalSpaces = try await store.spaces()
        XCTAssertEqual(spaces, originalSpaces)
        let counts = try await other.spaceCounts()
        let originalCounts = try await store.spaceCounts()
        XCTAssertEqual(counts[spaces[0].id]?.messages, originalCounts[spaces[0].id]?.messages)
        XCTAssertGreaterThanOrEqual(counts[spaces[0].id]?.messages ?? 0, 2, "the space's member and its rule's match")
        let senderRules = try await other.senderRules()
        let originalSenderRules = try await store.senderRules()
        // The files are equal byte for byte (above); the running store also holds sub-second times
        // its file doesn't, so the rules are compared by what they do.
        XCTAssertEqual(senderRules.map { "\($0.id) \($0.account) \($0.scope) \($0.action)" },
                       originalSenderRules.map { "\($0.id) \($0.account) \($0.scope) \($0.action)" })
        XCTAssertEqual(senderRules.count, 1)
        let rules = try await other.classificationRules()
        let originalRules = try await store.classificationRules()
        XCTAssertEqual(rules.map { "\($0.id) \($0.account) \($0.scope) \($0.purpose)" },
                       originalRules.map { "\($0.id) \($0.account) \($0.scope) \($0.purpose)" })
        XCTAssertEqual(rules.count, 1)
        let correction = try await other.correction(of: ids["invoice"]!)
        XCTAssertEqual(correction?.purpose, .transaction)
        let attachment = try await other.blobData(Hashing.sha256Hex(pdf))
        XCTAssertEqual(attachment, pdf)
    }

    func testArchivesNeverOverwriteAndDefaultToADatedName() async throws {
        let store = try await MailStore.open(locations)
        try await seed(store)
        let first = try await write(store)
        let second = try await write(store)
        XCTAssertEqual(first.file.lastPathComponent, "Backup.gkmarchive")
        XCTAssertEqual(second.file.lastPathComponent, "Backup 2.gkmarchive")
        let dated = try await store.writeEncryptedArchive(to: destination, now: Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertTrue(dated.file.lastPathComponent.hasPrefix("Mail Archive 2026-11-"), dated.file.lastPathComponent)
        XCTAssertNotEqual(dated.recoveryKey, first.recoveryKey, "every archive gets its own key")
    }

    /// A changed original is left out and said so, as export does; the rest restores.
    func testAChangedOriginalIsLeftOutAndReported() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let changed = try await store.message(ids["reply"]!).emlURL
        try Data("tampered".utf8).write(to: changed)
        let result = try await write(store)
        XCTAssertEqual(result.failed, [ids["reply"]!])
        XCTAssertEqual(result.messages, 3)
        let restored = try EncryptedArchive.restore(result.file, recoveryKey: fixedKey, into: fresh)
        XCTAssertEqual(restored.messages, 3)
        let other = try await MailStore.open(fresh)
        let count = try await other.messageCount()
        XCTAssertEqual(count, 3)
    }

    // MARK: Keys

    func testRecoveryKeyIsTwentyEightCharactersInGroupsAndCatchesTypos() throws {
        let key = ArchiveRecoveryKey.generate()
        XCTAssertEqual(key.groups.count, 7)
        XCTAssertTrue(key.groups.allSatisfy { $0.count == 4 })
        XCTAssertEqual(try ArchiveRecoveryKey(key.text), key)
        XCTAssertEqual(key.description, "ArchiveRecoveryKey(hidden)", "never printed")
        XCTAssertNotEqual(ArchiveRecoveryKey.generate(), key)

        // O for zero and I or L for one are read the way they were meant.
        let text = fixedKey.text
        let lookalikes = text.replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l")
        XCTAssertEqual(try ArchiveRecoveryKey(lookalikes), fixedKey)

        // One character wrong, one missing, one that can't be in a key: a typo, not "wrong key".
        var symbols = Array(text)
        symbols[5] = symbols[5] == "A" ? "B" : "A"
        XCTAssertThrowsError(try ArchiveRecoveryKey(String(symbols))) { XCTAssertEqual($0 as? EncryptedArchiveError, .malformedRecoveryKey) }
        XCTAssertThrowsError(try ArchiveRecoveryKey(String(text.dropLast()))) { XCTAssertEqual($0 as? EncryptedArchiveError, .malformedRecoveryKey) }
        XCTAssertThrowsError(try ArchiveRecoveryKey(text.replacingOccurrences(of: "-", with: "U"))) {
            XCTAssertEqual($0 as? EncryptedArchiveError, .malformedRecoveryKey)
        }
    }

    func testAWrongKeyRestoresNothing() async throws {
        let store = try await MailStore.open(locations)
        try await seed(store)
        let result = try await write(store)
        XCTAssertThrowsError(try EncryptedArchive.restore(result.file, recoveryKey: .generate(), into: fresh)) {
            XCTAssertEqual($0 as? EncryptedArchiveError, .wrongKey)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.mailFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.deviceFolder.path))
    }

    // MARK: Tampering

    /// The archive's records: where each starts and how long it is, prefix included.
    private func records(_ data: Data) -> [Range<Int>] {
        var offset = ArchiveFormat.magic.count
        let headerLength = Int(data[offset..<offset + 4].bigEndianUInt32)
        offset += 4 + headerLength
        var ranges: [Range<Int>] = []
        while offset < data.count {
            let length = Int(data[offset..<offset + 4].bigEndianUInt32 & ~ArchiveFormat.finalFlag)
            ranges.append(offset..<offset + 4 + length)
            offset += 4 + length
        }
        return ranges
    }

    private func assertRestoreFails(_ data: Data, with expected: EncryptedArchiveError, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let url = root.appendingPathComponent("changed-\(UUID().uuidString).gkmarchive")
        try data.write(to: url)
        let target = StoreLocations(mailFolder: root.appendingPathComponent("Restore \(UUID().uuidString)/Mail"),
                                    deviceFolder: root.appendingPathComponent("Restore \(UUID().uuidString)/Support"))
        XCTAssertThrowsError(try EncryptedArchive.restore(url, recoveryKey: fixedKey, into: target), message, file: file, line: line) {
            XCTAssertEqual($0 as? EncryptedArchiveError, expected, message, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.mailFolder.path), "\(message): nothing restored", file: file, line: line)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: target.mailFolder.deletingLastPathComponent().path)) ?? []
        XCTAssertEqual(leftovers, [], "\(message): staging removed", file: file, line: line)
    }

    func testChangedReorderedDroppedOrCutRecordsAreRefused() async throws {
        let store = try await MailStore.open(locations)
        try await seed(store)
        let original = try Data(contentsOf: try await write(store).file)
        let ranges = records(original)
        XCTAssertGreaterThan(ranges.count, 6, "the test mailbox spans many records")
        XCTAssertEqual(try EncryptedArchive.restore(writeCopy(original), recoveryKey: fixedKey, into: fresh).messages, 4, "the untouched copy restores")

        var flipped = original
        flipped[ranges[2].lowerBound + 40] ^= 0x01
        try assertRestoreFails(flipped, with: .damaged, "one bit changed in a record")

        // Two full records swapped: same lengths, wrong places.
        var swapped = original
        swapped.replaceSubrange(ranges[1], with: original[ranges[2]])
        swapped.replaceSubrange(ranges[2], with: original[ranges[1]])
        XCTAssertEqual(ranges[1].count, ranges[2].count)
        try assertRestoreFails(swapped, with: .damaged, "records reordered")

        var dropped = original
        dropped.removeSubrange(ranges[3])
        try assertRestoreFails(dropped, with: .damaged, "a record dropped")

        try assertRestoreFails(original.prefix(ranges.last!.lowerBound), with: .truncated, "the final record cut off")
        try assertRestoreFails(original.prefix(ranges.last!.lowerBound - 100), with: .truncated, "cut part way through a record")
        try assertRestoreFails(original.prefix(ranges[0].lowerBound), with: .truncated, "only the header left")

        // The final record marked not final: it no longer authenticates.
        var unmarked = original
        unmarked[ranges.last!.lowerBound] &= 0x7f
        try assertRestoreFails(unmarked, with: .damaged, "the final mark removed")

        // A not-final record marked final, the rest cut: also refused.
        var early = Data(original.prefix(ranges[2].upperBound))
        early[ranges[2].lowerBound] |= 0x80
        try assertRestoreFails(early, with: .damaged, "an early record marked final")

        try assertRestoreFails(original + Data([0]), with: .damaged, "a byte after the end")
        try assertRestoreFails(original + original[ranges[1]], with: .damaged, "a record repeated after the end")
    }

    private func writeCopy(_ data: Data) throws -> URL {
        let url = root.appendingPathComponent("copy-\(UUID().uuidString).gkmarchive")
        try data.write(to: url)
        return url
    }

    func testAChangedHeaderIsRefused() async throws {
        let store = try await MailStore.open(locations)
        try await seed(store)
        let original = try Data(contentsOf: try await write(store).file)
        let header = original.range(of: Data("\"created\":\"2026".utf8))!
        var changed = original
        changed[header.upperBound - 1] = UInt8(ascii: "5") // created 2025: the header digest no longer matches
        try assertRestoreFails(changed, with: .damaged, "the creation date changed")

        var newer = original
        let format = original.range(of: Data("\"format\":1".utf8))!
        newer[format.upperBound - 1] = UInt8(ascii: "9")
        try assertRestoreFails(newer, with: .unsupportedFormat(9), "a newer format")

        try assertRestoreFails(Data("not an archive at all".utf8), with: .notAnArchive, "another file")
        try assertRestoreFails(Data("GKM".utf8), with: .notAnArchive, "a tiny file")
    }

    // MARK: Paths

    /// An archive is input from outside: a path that would leave the restored folders is
    /// refused even when the archive itself authenticates (written here with the real writer).
    func testPathsThatWouldEscapeAreRefused() throws {
        for path in ["mail/../outside.eml", "mail/accounts/../../x", "/etc/passwd", "mail/.hidden", "device/state/sync.sqlite",
                     "device/metadata/../../index.sqlite", "mail//double", "mail", "other/file"] {
            let url = root.appendingPathComponent("crafted-\(UUID().uuidString).gkmarchive")
            try craft(url, entries: [("mail/layout.json", Data("{}".utf8)), (path, Data("x".utf8))])
            let target = StoreLocations(mailFolder: root.appendingPathComponent("R-\(UUID().uuidString)/Mail"),
                                        deviceFolder: root.appendingPathComponent("R-\(UUID().uuidString)/Support"))
            XCTAssertThrowsError(try EncryptedArchive.restore(url, recoveryKey: fixedKey, into: target), path) {
                XCTAssertEqual($0 as? EncryptedArchiveError, .unsafePath(path), path)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.mailFolder.path), path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.eml").path))
        }
        // The same entry twice is a malformed archive.
        let url = root.appendingPathComponent("twice.gkmarchive")
        try craft(url, entries: [("mail/layout.json", Data("{}".utf8)), ("mail/layout.json", Data("{}".utf8))])
        XCTAssertThrowsError(try EncryptedArchive.restore(url, recoveryKey: fixedKey, into: fresh)) {
            XCTAssertEqual($0 as? EncryptedArchiveError, .damaged)
        }
    }

    func testRestoreNeedsAnEmptyDestination() async throws {
        let store = try await MailStore.open(locations)
        try await seed(store)
        let result = try await write(store)
        XCTAssertThrowsError(try EncryptedArchive.restore(result.file, recoveryKey: fixedKey, into: locations)) {
            XCTAssertEqual($0 as? EncryptedArchiveError, .destinationNotEmpty("Mail"))
        }
        // An empty folder made for it is fine.
        try FileManager.default.createDirectory(at: fresh.mailFolder, withIntermediateDirectories: true)
        XCTAssertEqual(try EncryptedArchive.restore(result.file, recoveryKey: fixedKey, into: fresh).messages, 4)
    }

    /// Writes an archive with the real format writer and arbitrary entries.
    private func craft(_ url: URL, entries: [(String, Data)]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let archiveKey = SymmetricKey(size: .bits256)
        let archiveID = ArchiveFormat.randomBytes(16)
        let header = ArchiveHeader(format: 1, archive: archiveID.base64EncodedString(), created: Date(), cipher: ArchiveHeader.cipherName,
                                   chunkSize: smallChunks, keys: [try ArchiveFormat.recoverySlot(for: archiveKey, recovery: fixedKey, archive: archiveID)])
        let headerBytes = try ArchiveFormat.headerEncoder.encode(header)
        var start = ArchiveFormat.magic
        start.append(bigEndian: UInt32(headerBytes.count))
        start.append(headerBytes)
        try output.write(contentsOf: start)
        let payload = try ArchivePayloadWriter(sealer: ArchiveSealer(output: output, key: archiveKey, headerDigest: Data(SHA256.hash(data: headerBytes)),
                                                                     chunkSize: smallChunks))
        for (path, data) in entries { try payload.add(path: path, data: data) }
        try payload.finish()
    }
}
