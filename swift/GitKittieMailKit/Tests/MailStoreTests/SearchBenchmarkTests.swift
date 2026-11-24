import XCTest
import MailCore
@testable import MailStore

/// GKM-016 acceptance: a known message is found in under a second in a 100,000-message mailbox.
/// The mailbox is generated straight into the index through the same `IndexRecord` the store
/// builds on ingest and rebuild; search reads only the index, so that is what is measured.
/// Heavy (about a minute), so it runs when `GKM_BENCHMARK=1`:
///
///     GKM_BENCHMARK=1 swift test --filter SearchBenchmarkTests
final class SearchBenchmarkTests: XCTestCase {
    func testAKnownMessageIsFoundInUnderASecondAt100k() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GKM_BENCHMARK"] == "1", "set GKM_BENCHMARK=1 to run the 100k benchmark")
        let count = Int(ProcessInfo.processInfo.environment["GKM_BENCHMARK_COUNT"] ?? "") ?? 100_000
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try MailIndex(url: root.appendingPathComponent("index.sqlite"))

        let words = ["invoice", "meeting", "garden", "travel", "receipt", "project", "review", "schedule", "update", "photos",
                     "dinner", "report", "contract", "holiday", "budget", "delivery", "order", "weekly", "notes", "plan"]
        let people = (0..<500).map { MailAddress(name: "Person \($0)", address: "person\($0)@example.\(["com", "org", "net"][$0 % 3])") }
        let accounts = [MailAccountID("work"), MailAccountID("home")]
        let target = count / 3
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var generator = SystemRandomNumberGenerator()

        let fill = Date()
        try index.replaceAll { insert in
            for n in 0..<count {
                let id = MailMessageID()
                let subjectWords = (0..<4).map { _ in words.randomElement(using: &generator)! }
                var body = (0..<60).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
                if n == target { body += " the quokka zirconium handover" }
                let from = people[n % people.count]
                let messageID = "m\(n)@example.com"
                let parent = n % 4 == 0 || n == 0 ? [] : ["m\(n - 1)@example.com"]
                let front = MessageFrontMatter(
                    schema: 1, id: id, account: accounts[(n / 4) % 2], messageId: messageID, inReplyTo: parent, references: parent,
                    from: [from], to: [people[(n + 7) % people.count]], cc: [], replyTo: [], subject: subjectWords.joined(separator: " "),
                    date: start.addingTimeInterval(Double(n) * 300), received: start, eml: "\(id).eml", emlSha256: String(repeating: "0", count: 64),
                    emlSize: 2_000, attachments: [])
                let message = ParsedMessage(messageID: messageID, from: [from], subject: front.subject, date: front.date, textBody: body)
                try insert(IndexRecord(front: front, message: message, path: "accounts/x/\(id).eml"))
            }
        }
        let fillSeconds = Date().timeIntervalSince(fill)
        XCTAssertEqual(try index.count(), count)

        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, TimeInterval) {
            let began = Date()
            let value = try body()
            let elapsed = Date().timeIntervalSince(began)
            print("BENCHMARK \(label): \(String(format: "%.1f", elapsed * 1_000)) ms")
            return (value, elapsed)
        }

        let (known, knownTime) = try time("known message (2 words)") { try index.summaries(matching: SearchQuery(text: "quokka zirconium"), limit: 200) }
        XCTAssertEqual(known.count, 1)
        XCTAssertLessThan(knownTime, 1.0)
        let (prefix, prefixTime) = try time("known message (prefix 'zirc')") { try index.summaries(matching: SearchQuery(text: "zirc"), limit: 200) }
        XCTAssertEqual(prefix.count, 1)
        XCTAssertLessThan(prefixTime, 1.0)
        let (common, commonTime) = try time("common word, top 200") { try index.summaries(matching: SearchQuery(text: "invoice"), limit: 200) }
        XCTAssertEqual(common.count, 200)
        XCTAssertLessThan(commonTime, 1.0)
        let (filtered, filteredTime) = try time("word + participant + account + date") {
            try index.summaries(matching: SearchQuery(text: "budget", participant: "person42", account: accounts[0],
                                                      after: start, before: start.addingTimeInterval(Double(count) * 300)), limit: 200)
        }
        XCTAssertFalse(filtered.isEmpty)
        XCTAssertLessThan(filteredTime, 1.0)
        let (threads, threadTime) = try time("unified inbox, first 200 threads") { try index.threads(matching: SearchQuery(), limit: 200, offset: 0) }
        XCTAssertEqual(threads.count, 200)
        XCTAssertEqual(threads.first?.messageCount, 4, "chains of four replies")
        XCTAssertLessThan(threadTime, 1.0)
        print("BENCHMARK index build for \(count) messages: \(String(format: "%.1f", fillSeconds)) s")
    }
}
