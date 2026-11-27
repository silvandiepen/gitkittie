import XCTest
import MailCore
import MailStore

/// The encrypted archive through the app model (GKM-032): the key shown once and confirmed,
/// discarding an archive whose key was not saved, and restoring into a new folder with its own
/// device state. A real store in a temporary folder; no fakes.
@MainActor
final class EncryptedArchiveAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var chosen: URL!
    private let work = MailAccountID("work")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm032-app-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        for (index, subject) in ["Site plan", "Invoice", "Dinner"].enumerated() {
            let eml = "From: Bo <bo@example.org>\r\nTo: ada@example.com\r\nSubject: \(subject)\r\nDate: Tue, 24 Nov 2026 0\(index):00:00 +0000\r\nMessage-ID: <m\(index)@example.org>\r\n\r\nHello.\r\n"
            try await store.ingest(Data(eml.utf8), account: work)
        }
        try await store.setSenderRules([SenderRule(account: work, scope: .sender("bo@example.org"), action: .mute)])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openedModel() async -> AppModel {
        let model = AppModel(locations: locations)
        await model.open()
        return model
    }

    func testTheKeyIsShownOnceAndClosesOnlyWhenItsLastGroupIsTypedBack() async throws {
        let model = await openedModel()
        await model.writeEncryptedArchive(to: chosen)
        XCTAssertNil(model.encryptedArchive.error)
        let written = try XCTUnwrap(model.encryptedArchive.written)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.file.path))
        XCTAssertEqual(written.file.pathExtension, "gkmarchive")
        XCTAssertEqual(written.keyGroups.count, 7)
        XCTAssertTrue(written.summary.hasPrefix("3 messages, with your spaces, rules and corrections"), written.summary)
        XCTAssertTrue(model.encryptedArchive.keyFileText?.contains(written.keyText) == true)
        XCTAssertEqual(model.encryptedArchive.keyFileName, "\(written.file.deletingPathExtension().lastPathComponent) Recovery Key.txt")

        XCTAssertFalse(model.encryptedArchive.isConfirmed)
        XCTAssertFalse(model.encryptedArchive.finish(), "not before it is confirmed")
        XCTAssertNotNil(model.encryptedArchive.written)
        model.encryptedArchive.confirmation = written.keyGroups[0] == written.keyGroups[6] ? "ZZZZ" : written.keyGroups[0]
        XCTAssertFalse(model.encryptedArchive.isConfirmed, "another group is not the last one")
        model.encryptedArchive.confirmation = " " + written.keyGroups[6].lowercased() + " "
        XCTAssertTrue(model.encryptedArchive.isConfirmed)
        XCTAssertTrue(model.encryptedArchive.finish())
        XCTAssertNil(model.encryptedArchive.written, "the key is gone from the app")
        XCTAssertEqual(model.encryptedArchive.confirmation, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.file.path), "the archive stays")
    }

    func testClosingWithoutSavingTheKeyRemovesTheArchive() async throws {
        let model = await openedModel()
        await model.writeEncryptedArchive(to: chosen)
        let written = try XCTUnwrap(model.encryptedArchive.written)
        model.encryptedArchive.discard()
        XCTAssertNil(model.encryptedArchive.written)
        XCTAssertNil(model.encryptedArchive.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.file.path))
    }

    func testRestoreMakesANewFolderWithItsOwnDeviceStateThatTheStoreOpens() async throws {
        let model = await openedModel()
        await model.writeEncryptedArchive(to: chosen)
        let written = try XCTUnwrap(model.encryptedArchive.written)
        model.encryptedArchive.confirmation = written.keyGroups[6]
        model.encryptedArchive.finish()

        // Typed the way a person might: lower case, spaces between the groups.
        await model.restoreEncryptedArchive(written.file, recoveryKey: written.keyGroups.joined(separator: " ").lowercased(), into: chosen)
        XCTAssertNil(model.encryptedArchive.error)
        let restored = try XCTUnwrap(model.encryptedArchive.restored)
        XCTAssertEqual(restored.folder.lastPathComponent, "Restored Mail")
        XCTAssertTrue(restored.summary.hasPrefix("3 messages restored into “Restored Mail”"), restored.summary)

        // The restored folder's device state sits where `MailFolderLocation` looks for it, so
        // its sender rules are there when it is used as the mail folder.
        let restoredLocations = MailFolderLocation.locations(for: restored.folder, standard: locations)
        let store = try await MailStore.open(restoredLocations)
        let count = try await store.messageCount()
        XCTAssertEqual(count, 3)
        let rules = try await store.senderRules()
        XCTAssertEqual(rules.map(\.scope), [.sender("bo@example.org")])
        XCTAssertNotEqual(restoredLocations.deviceFolder, locations.deviceFolder)

        // A second restore never lands in the first one.
        model.encryptedArchive.restored = nil
        await model.restoreEncryptedArchive(written.file, recoveryKey: written.keyText, into: chosen)
        XCTAssertEqual(model.encryptedArchive.restored?.folder.lastPathComponent, "Restored Mail 2")
    }

    func testAWrongOrMistypedKeySaysSoAndLeavesNoFolder() async throws {
        let model = await openedModel()
        await model.writeEncryptedArchive(to: chosen)
        let written = try XCTUnwrap(model.encryptedArchive.written)
        model.encryptedArchive.confirmation = written.keyGroups[6]
        model.encryptedArchive.finish()

        await model.restoreEncryptedArchive(written.file, recoveryKey: ArchiveRecoveryKey.generate().text, into: chosen)
        XCTAssertEqual(model.encryptedArchive.error, EncryptedArchiveError.wrongKey.description)
        XCTAssertNil(model.encryptedArchive.restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chosen.appendingPathComponent("Restored Mail").path))

        model.encryptedArchive.error = nil
        await model.restoreEncryptedArchive(written.file, recoveryKey: String(written.keyText.dropLast()), into: chosen)
        XCTAssertEqual(model.encryptedArchive.error, EncryptedArchiveError.malformedRecoveryKey.description)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chosen.appendingPathComponent("Restored Mail").path))
    }
}
