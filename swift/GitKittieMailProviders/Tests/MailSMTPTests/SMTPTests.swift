import Foundation
import MailProvider
import NIOCore
import NIOEmbedded
import XCTest
@testable import MailSMTP

final class SMTPEncodingTests: XCTestCase {
    func testDotStuffingAndLineEndings() {
        let input = Data("Subject: x\n\n.starts with dot\r\n..two\rbare CR\nlast".utf8)
        let output = String(decoding: SMTPTransaction.dotStuffed(input), as: UTF8.self)
        XCTAssertEqual(output, "Subject: x\r\n\r\n..starts with dot\r\n...two\r\nbare CR\r\nlast\r\n")
    }

    func testALoneDotLineCannotEndTheMessageEarly() {
        let output = String(decoding: SMTPTransaction.dotStuffed(Data("a\r\n.\r\nb\r\n".utf8)), as: UTF8.self)
        XCTAssertFalse(output.contains("\r\n.\r\n"))
        // SMTP smuggling (bare LF before a dot) is normalised away too.
        let smuggle = String(decoding: SMTPTransaction.dotStuffed(Data("a\n.\nMAIL FROM:<x@example.com>\n".utf8)), as: UTF8.self)
        XCTAssertFalse(smuggle.contains("\r\n.\r\n"))
    }

    func testEnvelopeAddressesCannotInjectCommands() {
        XCTAssertNoThrow(try SMTPTransaction.validate(address: "me@example.com"))
        for bad in ["me@example.com>\r\nRCPT TO:<x@example.org", "a b@example.com", "", "noat", "<a@example.com>"] {
            XCTAssertThrowsError(try SMTPTransaction.validate(address: bad), bad)
        }
    }
}

final class SMTPReplyDecoderTests: XCTestCase {
    private func decode(_ chunks: [String]) async -> (replies: [SMTPReply], error: (any Error)?) {
        let (stream, continuation) = AsyncThrowingStream<SMTPReply, any Error>.makeStream()
        let channel = EmbeddedChannel(handler: SMTPReplyDecoder(continuation: continuation))
        for chunk in chunks {
            // A decoding error closes the channel; later writes then fail, which is expected.
            _ = try? channel.writeInbound(channel.allocator.buffer(string: chunk))
        }
        continuation.finish()
        _ = try? channel.finish()
        var replies: [SMTPReply] = []
        do {
            for try await reply in stream { replies.append(reply) }
            return (replies, nil)
        } catch {
            return (replies, error)
        }
    }

    func testMultilineRepliesSplitAcrossReads() async {
        let result = await decode(["220 hi\r\n250-mail.exam", "ple.com\r\n250-SIZE 1000\r\n250 AUTH PLAIN LOGIN\r\n"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.replies.map(\.code), [220, 250])
        XCTAssertEqual(result.replies[1].lines, ["mail.example.com", "SIZE 1000", "AUTH PLAIN LOGIN"])
    }

    func testMalformedReplyFails() async {
        let notSMTP = await decode(["hello\r\n"])
        XCTAssertNotNil(notSMTP.error)
        let codeChange = await decode(["250-a\r\n251 b\r\n"])
        XCTAssertNotNil(codeChange.error)
        let endless = await decode([String(repeating: "x", count: 5000)])
        XCTAssertNotNil(endless.error)
    }

    func testBytesAfterTheSTARTTLSReplyAreRejected() async {
        let (stream, continuation) = AsyncThrowingStream<SMTPReply, any Error>.makeStream()
        let decoder = SMTPReplyDecoder(continuation: continuation)
        let channel = EmbeddedChannel(handler: decoder)
        decoder.expectingTLSUpgrade = true
        // An attacker appends a fake EHLO reply in plaintext right behind the 220.
        _ = try? channel.writeInbound(channel.allocator.buffer(string: "220 go ahead\r\n250 AUTH PLAIN\r\n"))
        continuation.finish()
        var codes: [Int] = []
        var failed = false
        do { for try await reply in stream { codes.append(reply.code) } } catch { failed = true }
        XCTAssertEqual(codes, [220])
        XCTAssertTrue(failed)
        XCTAssertFalse(channel.isActive)
    }
}

