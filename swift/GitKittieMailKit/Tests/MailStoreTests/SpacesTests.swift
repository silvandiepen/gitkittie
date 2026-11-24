import XCTest
import MailCore
@testable import MailStore

/// Spaces (GKM-022): membership is metadata in `Mail/spaces/<id>.json`, never a copy of mail.
final class SpacesTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let work = MailAccountID("acct-work")
    private let home = MailAccountID("acct-home")
    private let now = Date(timeIntervalSince1970: 1_795_700_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seed(_ store: MailStore) async throws -> [String: MailMessageID] {
        var ids: [String: MailMessageID] = [:]
        ids["invoice"] = try await store.ingest(SyntheticMail.plain(subject: "Invoice 114 for the garden project", messageID: "inv@example.com",
                                                                    body: "Invoice attached."), account: work).id
        ids["reply"] = try await store.ingest(SyntheticMail.plain(from: "Bo Example <bo@example.org>", subject: "Re: Invoice 114",
                                                                  date: "Tue, 24 Nov 2026 12:00:00 +0000", messageID: "re@example.org",
                                                                  inReplyTo: "inv@example.com", body: "Paid."), account: work).id
        ids["news"] = try await store.ingest(SyntheticMail.plain(from: "Garden News <news@lists.example.net>", subject: "Weekly garden news",
                                                                 messageID: "news@example.net", body: "Tomatoes.",
                                                                 extraHeaders: ["List-Id: Garden News <garden.lists.example.net>"]), account: home).id
        ids["sub"] = try await store.ingest(SyntheticMail.plain(from: "Studio <hello@studio.example.com>", subject: "Moodboard",
                                                                messageID: "mood@example.com", body: "Pictures."), account: home).id
        return ids
    }

    private func emlFiles() -> [URL] {
        let walker = FileManager.default.enumerator(at: locations.mailFolder, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "eml" }
    }

    // MARK: Membership

    func testAMessageInTwoSpacesExistsOnceOnDisk() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let garden = try await store.createSpace(name: "Garden", now: now)
        let money = try await store.createSpace(name: "Money", icon: "banknote.fill", color: "green", now: now)
        try await store.addMessages([ids["invoice"]!], to: garden.id, now: now)
        try await store.addMessages([ids["invoice"]!], to: money.id, now: now)

        XCTAssertEqual(emlFiles().count, 4, "being in two spaces copies nothing")
        let inGarden = try await store.search(SearchQuery(space: garden.id))
        let inMoney = try await store.search(SearchQuery(space: money.id))
        XCTAssertEqual(inGarden.map(\.id), [ids["invoice"]!])
        XCTAssertEqual(inMoney.map(\.id), [ids["invoice"]!])
        let containing = try await store.spaces(containing: ids["invoice"]!)
        XCTAssertEqual(containing, [garden.id, money.id])

        // The space file names the message; it holds none of its content.
        let file = try String(contentsOf: locations.mailFolder.appendingPathComponent("spaces/\(garden.id).json"), encoding: .utf8)
        XCTAssertTrue(file.contains(ids["invoice"]!.rawValue))
        XCTAssertFalse(file.contains("Invoice attached"))
    }

    func testThreadsAddAndRemoveTogetherAndRemovalIsRemembered() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let space = try await store.createSpace(name: "Garden", now: now)
        let thread = try await store.search(SearchQuery(text: "invoice")).first!.threadID
        let added = try await store.addThreads([thread], to: space.id, now: now)
        XCTAssertEqual(added, 2, "a conversation goes in whole")
        let threads = try await store.threads(SearchQuery(space: space.id))
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.messageCount, 2)

        let removed = try await store.removeMessages([ids["reply"]!], from: space.id, now: now)
        XCTAssertEqual(removed, 1)
        var saved = try await store.space(space.id)
        XCTAssertEqual(saved.memberIDs, [ids["invoice"]!])
        XCTAssertEqual(saved.excludedIDs, [ids["reply"]!])

        // Adding it back by hand clears the exclusion.
        try await store.addMessages([ids["reply"]!], to: space.id, now: now)
        saved = try await store.space(space.id)
        XCTAssertEqual(saved.memberIDs, [ids["invoice"]!, ids["reply"]!])
        XCTAssertTrue(saved.excluded.isEmpty)
    }

    func testDeletingASpaceTouchesNoMailNoMappingAndNoFlags() async throws {
        let store = try await MailStore.open(locations)
        let id = try await store.ingest(SyntheticMail.plain(subject: "Synced", messageID: "synced@example.com", body: "From the server."),
                                        account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 3, uid: 9),
                                        flags: MessageFlags(seen: true, flagged: true)).id
        let space = try await store.createSpace(name: "Project", now: now)
        try await store.addMessages([id], to: space.id, now: now)
        let before = try snapshot(excluding: "spaces")

        try await store.deleteSpace(space.id)

        XCTAssertEqual(try snapshot(excluding: "spaces"), before, "no file in the mail folder changes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.mailFolder.appendingPathComponent("spaces/\(space.id).json").path))
        let locationsAfter = try await store.remoteLocations(of: id, account: work)
        XCTAssertEqual(locationsAfter, [RemoteLocation(mailbox: "INBOX", uidValidity: 3, uid: 9)], "the provider mapping is untouched")
        let flags = try await store.flags(of: id)
        XCTAssertEqual(flags, MessageFlags(seen: true, flagged: true))
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1)
        let spaces = try await store.spaces()
        XCTAssertTrue(spaces.isEmpty)
        let gone = try await store.search(SearchQuery(space: space.id))
        XCTAssertTrue(gone.isEmpty)
    }

    /// Every file under the mail folder (outside `skip`) with its bytes' hash.
    private func snapshot(excluding skip: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let rootPath = locations.mailFolder.standardizedFileURL.path
        for case let url as URL in FileManager.default.enumerator(at: locations.mailFolder, includingPropertiesForKeys: [.isRegularFileKey])! {
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            guard !relative.hasPrefix(skip), (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[relative] = Hashing.sha256Hex(try Data(contentsOf: url))
        }
        return result
    }

    // MARK: Rules

    func testRulesMatchSenderDomainListSubjectAndAccount() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let space = try await store.createSpace(name: "Rules", now: now)

        func matches(_ rule: SpaceRule) async throws -> Set<MailMessageID> {
            let preview = try await store.previewRule(rule, for: space.id, samples: 10)
            XCTAssertEqual(preview.matchCount, preview.samples.count)
            return Set(preview.samples.map(\.id))
        }
        let sender = try await matches(SpaceRule(sender: " BO@example.org "))
        XCTAssertEqual(sender, [ids["reply"]!])
        let domain = try await matches(SpaceRule(domain: "@example.com"))
        XCTAssertEqual(domain, [ids["invoice"]!, ids["sub"]!], "a domain covers its subdomains")
        let notSuffix = try await matches(SpaceRule(domain: "ample.com"))
        XCTAssertTrue(notSuffix.isEmpty, "only whole labels match")
        let list = try await matches(SpaceRule(list: "Garden News <garden.lists.example.net>"))
        XCTAssertEqual(list, [ids["news"]!])
        let subject = try await matches(SpaceRule(subjectWords: "garden"))
        XCTAssertEqual(subject, [ids["invoice"]!, ids["news"]!])
        let both = try await matches(SpaceRule(subjectWords: "garden", account: home))
        XCTAssertEqual(both, [ids["news"]!])
        let wildcard = try await matches(SpaceRule(domain: "%"))
        XCTAssertTrue(wildcard.isEmpty, "typed text is never a wildcard")
    }

    func testSavingRulesFillsTheSpaceAndExclusionsHold() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let space = try await store.createSpace(name: "Garden", now: now)
        let rule = SpaceRule(subjectWords: "garden")
        let preview = try await store.previewRule(rule, for: space.id)
        XCTAssertEqual(preview.newCount, 2)

        let added = try await store.setRules([rule], of: space.id, now: now)
        XCTAssertEqual(added, 2)
        var saved = try await store.space(space.id)
        XCTAssertEqual(Set(saved.members.map(\.source)), [SpaceMember.rule(rule.id)])

        try await store.removeMessages([ids["news"]!], from: space.id, now: now)
        let again = try await store.applySpaceRules(now: now)
        XCTAssertEqual(again, 0, "a message taken out by hand stays out")

        // New mail that matches arrives (a sync or an import), and the rules pick it up.
        let late = try await store.ingest(SyntheticMail.plain(subject: "Garden shed quote", messageID: "shed@example.com", body: "Quote."),
                                          account: work).id
        let picked = try await store.applySpaceRules(now: now)
        XCTAssertEqual(picked, 1)
        saved = try await store.space(space.id)
        XCTAssertEqual(saved.memberIDs, [ids["invoice"]!, late])
        let updatedPreview = try await store.previewRule(rule, for: space.id)
        XCTAssertEqual(updatedPreview.matchCount, 3)
        XCTAssertEqual(updatedPreview.newCount, 0)
    }

    func testEmptyRulesAndNamesAreRefused() async throws {
        let store = try await MailStore.open(locations)
        let space = try await store.createSpace(name: "Garden", now: now)
        do {
            try await store.setRules([SpaceRule(subjectWords: "  ", account: work)], of: space.id)
            XCTFail("a rule with no message condition is refused")
        } catch MailStoreError.invalidSpace {}
        do {
            _ = try await store.createSpace(name: "   ")
            XCTFail("a space needs a name")
        } catch MailStoreError.invalidSpace {}
    }

    // MARK: Look and order

    func testRenameRecolourAndReorder() async throws {
        let store = try await MailStore.open(locations)
        let a = try await store.createSpace(name: "Alpha", now: now)
        let b = try await store.createSpace(name: "Beta", now: now)
        let c = try await store.createSpace(name: "Gamma", now: now)
        var names = try await store.spaces().map(\.name)
        XCTAssertEqual(names, ["Alpha", "Beta", "Gamma"])

        try await store.reorderSpaces([c.id, a.id], now: now)
        names = try await store.spaces().map(\.name)
        XCTAssertEqual(names, ["Gamma", "Alpha", "Beta"])

        let renamed = try await store.updateSpace(b.id, name: " Bravo ", icon: "leaf.fill", color: "mint", now: now.addingTimeInterval(60))
        XCTAssertEqual(renamed.name, "Bravo")
        let saved = try await store.space(b.id)
        XCTAssertEqual(saved.icon, "leaf.fill")
        XCTAssertEqual(saved.color, "mint")
        XCTAssertEqual(saved.modified, now.addingTimeInterval(60))
        XCTAssertEqual(saved.created, now)
    }

    // MARK: The format

    /// The file is the contract for later CloudKit sync (GKM-026): these keys, these shapes.
    func testTheFileFormatIsStable() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let space = try await store.createSpace(name: "Garden", icon: "leaf.fill", color: "green", now: now)
        try await store.addMessages([ids["invoice"]!], to: space.id, now: now)
        let rule = SpaceRule(id: "rule-1", domain: "example.net")
        try await store.setRules([rule], of: space.id, now: now)
        try await store.removeMessages([ids["news"]!], from: space.id, now: now)

        let data = try Data(contentsOf: locations.mailFolder.appendingPathComponent("spaces/\(space.id).json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["format", "id", "name", "icon", "color", "order", "created", "modified", "rules", "members", "excluded"])
        XCTAssertEqual(json["format"] as? Int, 1)
        XCTAssertEqual(json["id"] as? String, space.id.rawValue)
        XCTAssertEqual(json["created"] as? String, "2026-11-26T13:33:20Z")
        let rules = try XCTUnwrap(json["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["id"] as? String, "rule-1")
        XCTAssertEqual(rules.first?["domain"] as? String, "example.net")
        let member = try XCTUnwrap((json["members"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(member.keys), ["message", "account", "messageId", "emlSha256", "added", "source"])
        XCTAssertEqual(member["message"] as? String, ids["invoice"]!.rawValue)
        XCTAssertEqual(member["account"] as? String, work.rawValue)
        XCTAssertEqual(member["messageId"] as? String, "inv@example.com")
        XCTAssertEqual(member["source"] as? String, "manual")
        let excluded = try XCTUnwrap((json["excluded"] as? [[String: Any]])?.first)
        XCTAssertEqual(excluded["message"] as? String, ids["news"]!.rawValue)
        XCTAssertEqual(String(data: data, encoding: .utf8)?.contains("\n  \""), true, "pretty-printed, sorted keys: readable and diffable")
    }

    func testMembershipSurvivesAnIndexRebuildAndFilesFromElsewhereAreRead() async throws {
        var store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let space = try await store.createSpace(name: "Garden", now: now)
        try await store.addMessages([ids["sub"]!], to: space.id, now: now)

        // The index is a cache: delete it and the space is still there after opening.
        store = try await reopen(deleteIndex: true)
        var found = try await store.search(SearchQuery(space: space.id))
        XCTAssertEqual(found.map(\.id), [ids["sub"]!])

        // Another device (through a synced folder) adds a message to the space file.
        var edited = try await store.space(space.id)
        edited.members.append(SpaceMember(message: ids["news"]!, account: home, messageId: "news@example.net", emlSha256: "x",
                                          added: now, source: "manual"))
        try JSONCoding.prettyEncoder.encode(edited).write(to: locations.mailFolder.appendingPathComponent("spaces/\(space.id).json"))
        try await store.refreshSpaceIndex()
        found = try await store.search(SearchQuery(space: space.id))
        XCTAssertEqual(Set(found.map(\.id)), [ids["sub"]!, ids["news"]!])
        let counts = try await store.spaceCounts()
        XCTAssertEqual(counts[space.id], SpaceCount(messages: 2, unread: 2))
    }

    func testUnreadableAndNewerFilesAreLeftAlone() async throws {
        let store = try await MailStore.open(locations)
        let folder = locations.mailFolder.appendingPathComponent("spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let damaged = folder.appendingPathComponent("\(MailSpaceID().rawValue).json")
        try Data("{ not json".utf8).write(to: damaged)
        var newer = MailSpace(name: "From the future", created: now)
        newer.format = 2
        try JSONCoding.prettyEncoder.encode(newer).write(to: folder.appendingPathComponent("\(newer.id).json"))

        let spaces = try await store.spaces()
        XCTAssertEqual(spaces.map(\.name), ["From the future"], "a newer space is shown")
        let unreadable = try await store.unreadableSpaceFiles()
        XCTAssertEqual(unreadable, [damaged.lastPathComponent])
        do {
            try await store.updateSpace(newer.id, name: "Renamed", icon: "", color: "")
            XCTFail("a newer file is never rewritten")
        } catch MailStoreError.unsupportedSpaceFormat(2) {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path), "never deleted on doubt")
    }

    private func reopen(deleteIndex: Bool) async throws -> MailStore {
        if deleteIndex {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: locations.indexURL.path + suffix))
            }
        }
        return try await MailStore.open(locations)
    }
}

final class ListIdentifierTests: XCTestCase {
    func testListIdIsTheBracketedIdentifierLowercased() throws {
        XCTAssertEqual(MIMEMessageParser.listIdentifier("Garden News <Garden.Lists.Example.NET>"), "garden.lists.example.net")
        XCTAssertEqual(MIMEMessageParser.listIdentifier(" plain.example.org "), "plain.example.org")
        XCTAssertEqual(MIMEMessageParser.listIdentifier("\"Odd <name>\" <real.example.org>"), "real.example.org")
        XCTAssertNil(MIMEMessageParser.listIdentifier("<>"))
        XCTAssertNil(MIMEMessageParser.listIdentifier(nil))
        let parsed = try MIMEMessageParser().parse(SyntheticMail.plain(subject: "x", body: "y", extraHeaders: ["List-Id: <news.example.net>"]))
        XCTAssertEqual(parsed.listID, "news.example.net")
    }
}
