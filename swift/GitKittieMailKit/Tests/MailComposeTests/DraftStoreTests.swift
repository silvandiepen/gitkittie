import Foundation
import MailCore
import MailMIME
import MailStore
import XCTest
@testable import MailCompose

final class DraftStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var locations: StoreLocations {
        StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    private func sample() -> ComposeDraft {
        ComposeDraft(from: MailAddress(address: "alex.morgan@example.net"), to: [MailAddress(address: "kim@example.org")],
                     subject: "Plans", body: "First line")
    }

    func testDraftsLiveInTheMailFolderAndEverySaveIsARevision() async throws {
        let store = try DraftStore(locations: locations)
        XCTAssertEqual(store.folder, locations.mailFolder.appendingPathComponent("drafts", isDirectory: true))

        var draft = try await store.save(sample()).draft
        XCTAssertEqual(draft.revision, 1)
        XCTAssertEqual(draft.savedBy, store.deviceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("\(draft.id)/draft.json").path))

        draft.body = "First line\nSecond line"
        draft = try await store.save(draft).draft
        draft.body += "\nThird line"
        draft = try await store.save(draft).draft
        XCTAssertEqual(draft.revision, 3)

        // Nothing changed: no new revision.
        guard case .unchanged = try await store.save(draft) else { return XCTFail("expected unchanged") }

        let versions = try await store.versions(of: draft.id)
        XCTAssertEqual(versions.map(\.revision), [2, 1])
        XCTAssertEqual(versions.first?.body, "First line\nSecond line")
        let reloaded = try await store.draft(draft.id)
        XCTAssertEqual(reloaded, draft)
    }

    /// GKM-013 acceptance: a crash while writing loses at most what was typed since the last
    /// autosave. A new store over the same folder (a relaunch) has the last saved revision, and
    /// a write that died before its rename leaves the previous revision whole.
    func testARelaunchFindsTheLastSavedRevision() async throws {
        var draft = try await DraftStore(locations: locations).save(sample()).draft
        draft.body = "Saved before the crash"
        draft = try await DraftStore(locations: locations).save(draft).draft

        // What a process killed in the middle of a write leaves: a hidden partial file.
        let directory = locations.draftsFolder.appendingPathComponent(draft.id.rawValue)
        try Data("{\"torn".utf8).write(to: directory.appendingPathComponent(".draft.json.\(UUID().uuidString.lowercased()).partial"))

        let relaunched = try DraftStore(locations: locations)
        let drafts = try await relaunched.drafts()
        XCTAssertEqual(drafts.map(\.body), ["Saved before the crash"])
        XCTAssertEqual(drafts.first?.revision, 2)
        XCTAssertEqual(relaunched.deviceID, try DraftStore(locations: locations).deviceID, "the device id is stable")
    }

    func testAStaleSaveBecomesAConflictCopyAndOverwritesNothing() async throws {
        let store = try DraftStore(locations: locations)
        let saved = try await store.save(sample()).draft

        // Two windows (or two devices) start from revision 1.
        var here = saved, there = saved
        there.body = "Written on the other Mac"
        _ = try await store.save(there)
        here.body = "Written here"
        let result = try await store.save(here)
        guard case .conflict(let copy) = result else { return XCTFail("expected a conflict copy, got \(result)") }
        XCTAssertNotEqual(copy.id, saved.id)
        XCTAssertEqual(copy.conflictOf, saved.id)
        XCTAssertEqual(copy.body, "Written here")

        let bodies = try await store.drafts().map(\.body).sorted()
        XCTAssertEqual(bodies, ["Written here", "Written on the other Mac"])
    }

    func testSyncToolConflictFilesAreAdoptedAsDrafts() async throws {
        let store = try DraftStore(locations: locations)
        var draft = try await store.save(sample()).draft
        let attachment = try await store.addAttachment(Data("plan".utf8), filename: "plan.txt", mimeType: "text/plain", to: draft.id)
        draft.attachments = [attachment]
        draft = try await store.save(draft).draft

        // iCloud Drive keeps both sides of a clash as "draft 2.json".
        var other = draft
        other.body = "From the other device"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(other).write(to: store.folder.appendingPathComponent("\(draft.id)/draft 2.json"))

        let drafts = try await store.drafts()
        XCTAssertEqual(drafts.count, 2)
        let adopted = try XCTUnwrap(drafts.first { $0.id != draft.id })
        XCTAssertEqual(adopted.conflictOf, draft.id)
        XCTAssertEqual(adopted.body, "From the other device")
        let adoptedFiles = try await store.outgoingAttachments(of: adopted)
        XCTAssertEqual(adoptedFiles.map(\.data), [Data("plan".utf8)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("\(draft.id)/draft 2.json").path))
    }

    func testAttachmentsAreStoredByContentAndCheckedOnTheWayOut() async throws {
        let store = try DraftStore(locations: locations)
        let draft = try await store.save(sample()).draft
        var withFile = draft
        withFile.attachments = [try await store.addAttachment(Data("hello".utf8), filename: "../../etc/passwd", mimeType: "text/plain\r\nX: y", to: draft.id)]
        XCTAssertEqual(withFile.attachments.first?.filename, "_.._etc_passwd")
        XCTAssertEqual(withFile.attachments.first?.mimeType, "application/octet-stream")
        let files = try await store.outgoingAttachments(of: withFile)
        XCTAssertEqual(files.first?.data, Data("hello".utf8))

        // A file changed behind the store's back is refused, not sent.
        let blob = store.folder.appendingPathComponent("\(draft.id)/attachments/\(withFile.attachments[0].sha256)")
        try Data("tampered".utf8).write(to: blob)
        do {
            _ = try await store.outgoingAttachments(of: withFile)
            XCTFail("a tampered attachment must not be sent")
        } catch ComposeError.missingAttachment(let name) {
            XCTAssertEqual(name, "_.._etc_passwd")
        }
    }

    func testOldVersionsArePrunedAndDeleteRemovesEverything() async throws {
        let store = try DraftStore(locations: locations)
        var draft = try await store.save(sample()).draft
        for index in 0..<(DraftStore.keptVersions + 5) {
            draft.body = "edit \(index)"
            draft = try await store.save(draft).draft
        }
        let versions = try await store.versions(of: draft.id)
        XCTAssertEqual(versions.count, DraftStore.keptVersions)
        try await store.delete(draft.id)
        let left = try await store.drafts()
        XCTAssertEqual(left, [])
        let gone = try await store.draft(draft.id)
        XCTAssertNil(gone)
    }

    func testForeignFoldersInDraftsAreIgnored() async throws {
        let store = try DraftStore(locations: locations)
        try FileManager.default.createDirectory(at: store.folder.appendingPathComponent("../../escape"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.folder.appendingPathComponent("not-a-uuid"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.folder.appendingPathComponent("not-a-uuid/draft.json"))
        let drafts = try await store.drafts()
        XCTAssertEqual(drafts, [])
        XCTAssertNil(DraftID("../x"))
    }
}
