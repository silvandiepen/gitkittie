import XCTest
@testable import MailStore

/// What runs for every arriving message must use an index, or a large first sync slows down
/// with every message stored (GKM-035, docs/Performance.md).
final class IndexQueryPlanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-plan-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPerMessageLookupsUseAnIndexNeverAScanOfTheAccount() throws {
        let index = try MailIndex(url: root.appendingPathComponent("index.sqlite"))
        for (sql, wanted) in [(MailIndex.claimantsSQL, ["messages_by_message_id"]),
                              (MailIndex.candidatesSQL, ["messages_by_message_id", "messages_by_fingerprint"])] {
            let plan = try index.queryPlan(sql)
            XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN") }, "\(sql)\n\(plan)")
            for name in wanted {
                XCTAssertTrue(plan.contains { $0.contains("USING INDEX \(name) (account_id=? AND") }, "\(name) in \(plan)")
            }
        }
    }
}
