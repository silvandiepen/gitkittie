import Foundation
import MailProvider
import MailStore
import XCTest

/// Which stop on this device a store error is (GKM-091, MAIL-124): the account's status says it
/// in these terms, never as a network problem.
final class LocalStopTests: XCTestCase {
    func testLocalProblemsAreReadFromTheErrorsTheStoreThrows() {
        XCTAssertEqual(LocalStoreProblem(MailStoreError.io(operation: "write", path: "/x", code: ENOSPC)), .diskFull)
        XCTAssertEqual(LocalStoreProblem(MailStoreError.io(operation: "open", path: "/x", code: EACCES)), .notWritable)
        XCTAssertEqual(LocalStoreProblem(MailStoreError.io(operation: "open", path: "/x", code: EROFS)), .notWritable)
        XCTAssertEqual(LocalStoreProblem(MailStoreError.io(operation: "open", path: "/x", code: ENOENT)), .folderUnavailable)
        XCTAssertEqual(LocalStoreProblem(MailStoreError.sqlite(code: 13, message: "database or disk is full")), .diskFull)
        XCTAssertEqual(LocalStoreProblem(MailStoreError.sqlite(code: 8, message: "readonly")), .notWritable)
        XCTAssertEqual(LocalStoreProblem(MailStoreError.sqlite(code: 11, message: "malformed")), .damaged)
        XCTAssertEqual(LocalStoreProblem(MailStoreError.sqlite(code: 10 | (3 << 8), message: "disk I/O error")), .folderUnavailable)
        XCTAssertEqual(LocalStoreProblem(CocoaError(.fileWriteNoPermission)), .notWritable)
        XCTAssertEqual(LocalStoreProblem(CocoaError(.fileWriteOutOfSpace)), .diskFull)
        XCTAssertEqual(LocalStoreProblem(MailStoreError.diskNearlyFull(freeBytes: 1, minimumFreeBytes: 2)), .diskFull)
        XCTAssertNil(LocalStoreProblem(MailStoreError.unparseableMessage("x")))
        XCTAssertNil(LocalStoreProblem(MailProviderError.connectionLost("reset")))
    }
}
