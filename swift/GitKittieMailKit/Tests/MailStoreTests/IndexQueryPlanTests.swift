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

    /// Every arriving message is numbered after the newest arrival (GKM-040). Without the
    /// partial index that is a read of every verdict per message, and the first sync of 50,000
    /// messages fell from 176 to 57 messages a second.
    func testTheNextArrivalNumberComesFromTheArrivalIndex() throws {
        let index = try MailIndex(url: root.appendingPathComponent("index.sqlite"))
        let plan = try index.queryPlan(MailIndex.latestArrivalSQL)
        XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN") }, "\(plan)")
        XCTAssertTrue(plan.contains { $0.contains("USING COVERING INDEX message_classes_by_arrival") }, "\(plan)")
    }

    /// The spaces of each arrival come from the membership index, not a scan of every space's
    /// members per message (GKM-037).
    func testArrivalsLookUpTheirSpacesThroughTheMembershipIndex() throws {
        let index = try MailIndex(url: root.appendingPathComponent("index.sqlite"))
        let plan = try index.queryPlan(MailIndex.arrivalsSQL)
        XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN") }, "\(plan)")
        XCTAssertTrue(plan.contains { $0.contains("space_members_by_message") }, "\(plan)")
    }
}
