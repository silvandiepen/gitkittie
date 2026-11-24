import NIOCore
import NIOEmbedded
import NIOIMAP
import XCTest
@testable import MailIMAP

/// A large folder's listing is one long response line (GKM-035): `UID SEARCH ALL` on 60,000
/// messages answers with about 350 KB in a single `* SEARCH` line.
final class LargeResponseTests: XCTestCase {
    private static func searchLine(count: Int) -> String {
        "* SEARCH " + (1...count).map { String(100_000 + $0 * 3) }.joined(separator: " ") + "\r\n"
    }

    private static func greetingAndSearch(_ count: Int, into channel: EmbeddedChannel) throws -> [UInt32] {
        try channel.writeInbound(channel.allocator.buffer(string: "* OK ready\r\n"))
        // As it comes off the network: in pieces (a TLS record is at most 16 KB).
        let line = Array(searchLine(count: count).utf8)
        for start in stride(from: 0, to: line.count, by: 4_096) {
            try channel.writeInbound(channel.allocator.buffer(bytes: line[start..<min(start + 4_096, line.count)]))
        }
        var uids: [UInt32] = []
        while let response = try channel.readInbound(as: Response.self) {
            if case .untagged(.mailboxData(.search(let found, _))) = response { uids += found.map(\.rawValue) }
        }
        return uids
    }

    func testTheSessionsHandlerReadsTheListingOfAFolderWithSixtyThousandMessages() throws {
        let channel = EmbeddedChannel(handler: IMAPConnector.makeClientHandler())
        defer { _ = try? channel.finish() }
        let uids = try Self.greetingAndSearch(60_000, into: channel)
        XCTAssertEqual(uids.count, 60_000)
        XCTAssertEqual(uids.last, 100_000 + 60_000 * 3)
    }

    /// Why the limit is set: with swift-nio-imap's default, a listing of 2,000 messages already
    /// ends the connection.
    func testTheLibraryDefaultRefusesTheListingOfAFolderWithTwoThousandMessages() {
        let channel = EmbeddedChannel(handler: IMAPClientHandler())
        defer { _ = try? channel.finish() }
        XCTAssertThrowsError(try Self.greetingAndSearch(2_000, into: channel))
    }
}
