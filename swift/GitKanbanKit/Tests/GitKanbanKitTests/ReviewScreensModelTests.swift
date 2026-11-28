import CoreGraphics
import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// What the review screens show for actions, assignment, due dates and browser checks
/// (GITKITTIE-135, GITKITTIE-136), over a real folder board: the words of "When decided" and the
/// banner, the Actions history and its Undo, the inbox order, the check grid, the viewport
/// layout, and the check session the Mac window and the iPhone screen answer through.
@MainActor
final class ReviewScreensModelTests: XCTestCase {
    private var root: URL!

    private static func card(_ id: String, status: String, claimedBy: String? = nil) -> String {
        """
        ---
        id: \(id)
        title: Card \(id)
        project: Pets
        status: \(status)
        assignee: claude
        updated_at: 2026-11-20T09:00:00Z
        picked_up_by: \(claimedBy ?? "null")
        claim_expires_at: \(claimedBy == nil ? "null" : "2099-01-01T14:00:00Z")
        ---

        # Card \(id)

        ## Activity log

        - 2026-11-20T09:00:00Z — `claude` created the task.
        """
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-screens-\(UUID().uuidString)", isDirectory: true)
        try write("README.md", """
        ---
        config: board
        lanes:
          - { id: todo, name: To do, folder: "1. To do", status: todo }
          - { id: in-progress, name: In Progress, folder: "2. In Progress", status: in-progress }
          - { id: in-review, name: In Review, folder: "3. In Review", status: in-review }
          - { id: testing, name: Testing, folder: "4. Testing", status: testing }
          - { id: done, name: Done, folder: "5. Done", status: done, terminal: true }
        users:
          - { id: sil, name: Sil, kind: human, github: \(NSUserName()) }
          - { id: herma, name: Herma, kind: human }
          - { id: claude, name: Claude, kind: agent }
        ---
        """)
        try write("Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        for lane in ["1. To do", "2. In Progress", "4. Testing", "5. Done"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Pets/\(lane)"), withIntermediateDirectories: true)
        }
        try write("Pets/3. In Review/PETS-1-site.md", Self.card("PETS-1", status: "in-review", claimedBy: "claude"))
        try write("Pets/3. In Review/PETS-2-badge.md", Self.card("PETS-2", status: "in-review", claimedBy: "herma"))
        try write("Pets/review/PETS-1-site/review.md", """
        ---
        config: review
        id: PETS-1-site
        card: PETS-1
        title: Site, round 1
        requested_by: claude
        requested_at: 2026-11-20T09:00:00Z
        on_accept: { to: testing }
        on_changes: { to: in-progress, comment: true, assign: claude }
        items:
          - id: hero
            file: hero.png
            status: approved
            decided_by: sil
            decided_at: 2026-11-20T09:30:00Z
          - id: badge
            file: badge.png
            status: pending
            on_accept: { move: PETS-2, to: testing }
        ---
        """)
        try write("Pets/review/PETS-1-page/review.md", """
        ---
        config: review
        id: PETS-1-page
        title: Page
        requested_by: claude
        requested_at: 2026-11-21T09:00:00Z
        checks:
          - id: page
            url: https://preview.example.app/onboarding
            title: Onboarding page
            sizes: [phone, desktop]
            appearance: [light, dark]
            checklist:
              - { id: hero, text: The headline fits }
              - { id: cta, text: The download button shows without scrolling }
        ---
        """)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    private func opened() async -> AppModel {
        let model = AppModel()
        let repo = AddedRepo(namespace: "folder", name: "Board", branch: "", isPrivate: true,
                             boards: [SelectedBoard(folder: "Pets", name: "Pets")], kind: .localFolder(path: root.path, bookmark: nil))
        model.addedRepos = [repo]
        await model.openBoard(repo, folder: "Pets")
        return model
    }

    private func request(_ model: AppModel, _ id: String) throws -> ReviewRequest {
        try XCTUnwrap(model.reviews.first { $0.id == id })
    }

    // MARK: Actions in words

    func testWhenDecidedSaysWhatEachDecisionWillDo() async throws {
        let model = await opened()
        let review = try request(model, "PETS-1-site")
        let lines = model.reviewActionLines(review)
        XCTAssertEqual(lines.map(\.text), [
            "Accept → move PETS-1 to Testing",
            "Changes → move PETS-1 to In Progress",
            "Accept → move PETS-2 to Testing",
        ])
        XCTAssertEqual(lines.map(\.entry), [nil, nil, "badge"])
        XCTAssertEqual(lines[1].detail, "your comments go on the card · assigned to Claude")
        XCTAssertTrue(lines.allSatisfy(\.laneFound))
        XCTAssertFalse(lines.contains(where: \.ran))
    }

    func testALaneTheBoardDoesNotHaveIsSaid() async throws {
        try write("Pets/review/PETS-1-site/review.md", try read("Pets/review/PETS-1-site/review.md")
            .replacingOccurrences(of: "on_accept: { to: testing }", with: "on_accept: { to: staging }"))
        let model = await opened()
        let line = try XCTUnwrap(model.reviewActionLines(try request(model, "PETS-1-site")).first)
        XCTAssertEqual(line.text, "Accept → move PETS-1 to staging")
        XCTAssertFalse(line.laneFound)
    }

    /// The last decision: the banner says what moved, asks about the card someone else holds,
    /// stays up while it asks, and Undo takes the move back; the history says so.
    func testTheBannerAfterTheLastDecisionAndItsUndo() async throws {
        let model = await opened()
        var review = try request(model, "PETS-1-site")
        let decided = await model.decide(review, item: review.items[1], status: .approved)
        XCTAssertTrue(decided)
        XCTAssertTrue(exists("Pets/4. Testing/PETS-1-site.md"))
        let report = try XCTUnwrap(model.reviewActionReport)
        let banner = model.reviewActionBanner(report)
        XCTAssertEqual(banner.message, "Moved PETS-1 to Testing")
        XCTAssertEqual(banner.undoable.map(\.run.card), ["PETS-1"])
        let until = AgentBoard.clock(try XCTUnwrap(Review.reviewDate("2099-01-01T14:00:00Z")))
        XCTAssertEqual(banner.prompts.map(\.text), ["PETS-2 is claimed by herma until \(until) — Move anyway?"])
        XCTAssertEqual(banner.prompts.first?.button, "Move Anyway")
        XCTAssertNil(banner.autoDismissAfter, "it waits for an answer about PETS-2")

        review = try request(model, "PETS-1-site")
        XCTAssertEqual(model.reviewActionLines(review).filter(\.ran).map(\.text), ["Accept → move PETS-1 to Testing"])
        let history = model.reviewActionHistory(review)
        // Newest first: the request's own move was recorded after the badge's skipped one.
        XCTAssertEqual(history.map(\.text), [
            "Moved PETS-1 to Testing",
            "Did not move PETS-2 to Testing: PETS-2 is claimed by herma until \(until).",
        ])
        XCTAssertEqual(history.map(\.mayUndo), [true, false])

        let undone = await model.undoReviewActions(banner)
        XCTAssertTrue(undone)
        XCTAssertTrue(exists("Pets/3. In Review/PETS-1-site.md"), "Undo moves the card back")
        review = try request(model, "PETS-1-site")
        XCTAssertTrue(model.reviewActionHistory(review).contains { $0.text == "Moved PETS-1 to Testing · undone" && !$0.mayUndo })
        XCTAssertEqual(model.reviewActionBanner(try XCTUnwrap(model.reviewActionReport)).undoable, [], "nothing left to undo on the banner")
    }

    func testABannerWithNothingToAskHidesItselfAfterEightSeconds() async throws {
        try write("Pets/review/PETS-1-site/review.md", try read("Pets/review/PETS-1-site/review.md")
            .replacingOccurrences(of: "    on_accept: { move: PETS-2, to: testing }\n", with: ""))
        let model = await opened()
        let review = try request(model, "PETS-1-site")
        _ = await model.decide(review, item: review.items[1], status: .approved)
        let banner = model.reviewActionBanner(try XCTUnwrap(model.reviewActionReport))
        XCTAssertEqual(banner.message, "Moved PETS-1 to Testing")
        XCTAssertTrue(banner.prompts.isEmpty)
        XCTAssertEqual(banner.autoDismissAfter, 8)
    }

    func testAChangedOutcomeIsOfferedWithTheLaneByName() async throws {
        let model = await opened()
        var review = try request(model, "PETS-1-site")
        _ = await model.decide(review, item: review.items[1], status: .approved)
        review = try request(model, "PETS-1-site")
        _ = await model.decide(review, item: review.items[1], status: .changesRequested, comment: "Smaller badge")
        let banner = model.reviewActionBanner(try XCTUnwrap(model.reviewActionReport))
        XCTAssertEqual(banner.prompts.map(\.text), ["Now changes requested — move PETS-1 to In Progress?"])
        XCTAssertEqual(banner.prompts.first?.button, "Move")
    }

    // MARK: Assignment

    func testForChipsNameTheBoardsPeople() async throws {
        try write("Pets/review/PETS-1-copy/review.md", """
        ---
        id: PETS-1-copy
        title: Copy
        for: [herma, sil]
        items:
          - { id: copy, file: copy.png, status: pending }
        ---
        """)
        let model = await opened()
        XCTAssertEqual(model.reviewForLabel(try request(model, "PETS-1-copy")), "For Herma and Sil")
        XCTAssertNil(model.reviewForLabel(try request(model, "PETS-1-site")), "for everyone: no chip")
        XCTAssertEqual(model.reviewingAs(try request(model, "PETS-1-site")), "Sil")
        XCTAssertNil(model.decisionBlockedReason(try request(model, "PETS-1-copy")))
    }

    // MARK: Due dates

    func testDueDatesInWords() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 15)))
        func label(_ due: String, done: Bool = false) -> ReviewDueLabel? { ReviewDue.label(due, done: done, now: now, calendar: calendar) }
        XCTAssertEqual(label("2026-11-28"), ReviewDueLabel(text: "Due today", overdue: false, soon: true))
        XCTAssertEqual(label("2026-11-29"), ReviewDueLabel(text: "Due tomorrow", overdue: false, soon: true))
        XCTAssertEqual(label("2026-12-01")?.text, "Due in 3 days")
        XCTAssertEqual(label("2026-12-12")?.text, "Due 12 Dec")
        XCTAssertEqual(label("2027-01-12")?.text, "Due 12 Jan 2027")
        XCTAssertEqual(label("2026-11-27"), ReviewDueLabel(text: "Due yesterday", overdue: true, soon: false))
        XCTAssertEqual(label("2026-11-25"), ReviewDueLabel(text: "Due 3 days ago", overdue: true, soon: false))
        XCTAssertEqual(label("2026-11-25", done: true)?.overdue, false, "nothing waits: not overdue")
        XCTAssertNil(label("soon"))
    }

    func testTheInboxPutsWhatIsDueFirst() {
        func review(_ id: String, asked: String, due: String? = nil, pending: Bool = true) -> ReviewRequest {
            Review.parse("""
            ---
            id: \(id)
            title: \(id)
            requested_at: \(asked)
            \(due.map { "due: \($0)" } ?? "")
            items:
              - { id: a, file: a.png, status: \(pending ? "pending" : "approved") }
            ---
            """, folder: "review/\(id)")
        }
        let ordered = AppModel.inboxOrder([
            review("new", asked: "2026-11-27T10:00:00Z"),
            review("due-late", asked: "2026-11-20T10:00:00Z", due: "2026-12-10"),
            review("due-soon", asked: "2026-11-19T10:00:00Z", due: "2026-11-29"),
            review("decided", asked: "2026-11-26T10:00:00Z", due: "2026-11-01", pending: false),
            review("old", asked: "2026-11-01T10:00:00Z"),
        ])
        XCTAssertEqual(ordered.map(\.id), ["due-soon", "due-late", "new", "decided", "old"])
    }

    // MARK: Browser checks

    func testChecksAreEntriesThatWaitUntilDecided() async throws {
        let model = await opened()
        let review = try request(model, "PETS-1-page")
        XCTAssertEqual(review.entries.map(\.id), ["check:page"])
        XCTAssertTrue(review.entries[0].isWaiting)
        XCTAssertEqual(review.hiddenIDs(for: .answered).checks, ["page"])
        XCTAssertEqual(review.hiddenIDs(for: .waiting).checks, [])
        XCTAssertEqual(review.summary.pendingChecks, 1)
    }

    func testTheGridAndWhatFailed() throws {
        var check = try XCTUnwrap(Review.parse("""
        ---
        id: grid
        title: Grid
        checks:
          - id: page
            url: https://x.example
            sizes: [phone, desktop]
            appearance: [light, dark]
            checklist:
              - { id: hero, text: Headline fits }
              - { id: cta, text: Button shows }
        ---
        """, folder: "review/grid").checks.first)
        check.results["phone.light"] = CheckResult(answers: ["hero": CheckAnswer(result: .pass), "cta": CheckAnswer(result: .pass)])
        check.results["phone.dark"] = CheckResult(answers: ["hero": CheckAnswer(result: .pass)])
        check.results["desktop.light"] = CheckResult(answers: ["hero": CheckAnswer(result: .pass),
                                                              "cta": CheckAnswer(result: .fail, note: "Below the fold")])
        check.results["desktop.dark"] = CheckResult(answers: ["hero": CheckAnswer(result: .note, note: "Low contrast"),
                                                             "cta": CheckAnswer(result: .pass)])
        XCTAssertEqual(check.grid.map(\.size.id), ["phone", "desktop"])
        XCTAssertEqual(check.grid.flatMap { $0.cells.map(\.state) },
                       [.passed, .partial(answered: 1, total: 2), .failed(1), .noted])
        XCTAssertEqual(check.label(forKey: "desktop.dark"), "Desktop, dark")
        XCTAssertEqual(check.label(forKey: "custom"), "Custom")
        XCTAssertEqual(check.progressLine, "Phone, light 2/2 · Phone, dark 1/2 · Desktop, light 2/2 · Desktop, dark 2/2")
        XCTAssertTrue(check.totalProgress == (7, 8))
        XCTAssertEqual(check.changesDraft, """
        Desktop, light: Button shows — Below the fold
        Desktop, dark: Headline fits — Low contrast
        """)
    }

    func testViewportLayout() {
        let desktop = CheckSize.presets[6], phone = CheckSize.presets[1], large = CheckSize.presets[2]
        // Mac: exact, scaled down to fit.
        let fits = CheckViewport.fit(phone, in: CGSize(width: 1500, height: 900))
        XCTAssertEqual(fits.shown, CGSize(width: 390, height: 844))
        XCTAssertFalse(fits.isScaled)
        XCTAssertEqual(fits.viewport, "390x844")
        let tall = CheckViewport.fit(large, in: CGSize(width: 1100, height: 717))
        XCTAssertEqual(tall.css, CGSize(width: 440, height: 956))
        XCTAssertEqual(tall.scale, 0.75, accuracy: 0.001)
        XCTAssertEqual(tall.percent, "75 %")
        XCTAssertTrue(tall.isScaled)
        // iPhone 17 Pro Max: the phone sizes are native, the desktop a scaled preview.
        let screen = CGSize(width: 440, height: 800)
        XCTAssertEqual(CheckViewport.nativeSizeID(among: [phone, large, desktop], screenWidth: 440), "phone-large")
        XCTAssertEqual(CheckViewport.nativeSizeID(among: [phone, desktop], screenWidth: 440), "phone")
        XCTAssertNil(CheckViewport.nativeSizeID(among: [desktop], screenWidth: 440))
        let native = CheckViewport.device(phone, among: [phone, desktop], available: screen)
        XCTAssertTrue(native.isNative)
        XCTAssertEqual(native.viewport, "440x800", "the device's own viewport is recorded")
        let preview = CheckViewport.device(desktop, among: [phone, desktop], available: screen)
        XCTAssertFalse(preview.isNative)
        XCTAssertTrue(preview.isScaled)
        XCTAssertEqual(preview.css, CGSize(width: 1440, height: 900))
        XCTAssertEqual(preview.shown.width, 440)
        XCTAssertEqual(CheckViewport.device(CheckSize(id: "default", label: "Default"), among: [], available: screen).viewport, "440x800")
    }

    // MARK: The check session

    func testAnswersShowAtOnceAndAreWrittenTogether() async throws {
        let model = await opened()
        let session = ReviewCheckSession(model: model, ref: try request(model, "PETS-1-page").ref, checkID: "page")
        session.debounce = .seconds(30)
        XCTAssertEqual(session.key, "phone.light")
        XCTAssertEqual(session.keys, ["phone.light", "phone.dark", "desktop.light", "desktop.dark"])
        session.viewport = "390x844"
        XCTAssertTrue(session.setAnswer("hero", .pass))
        XCTAssertTrue(session.setAnswer("cta", .fail, note: "Below the fold"))
        XCTAssertFalse(session.setAnswer("hero", .note, note: "  "), "a note needs its text")
        XCTAssertEqual(session.answer("cta"), CheckAnswer(result: .fail, note: "Below the fold"))
        XCTAssertTrue(session.progress == (2, 2))
        XCTAssertTrue(session.hasUnwrittenAnswers)
        XCTAssertFalse(try read("Pets/review/PETS-1-page/review.md").contains("Below the fold"), "not written yet")

        let flushed = await session.flush()
        XCTAssertTrue(flushed)
        XCTAssertFalse(session.hasUnwrittenAnswers)
        let stored = try XCTUnwrap(try request(model, "PETS-1-page").checks.first?.results["phone.light"])
        XCTAssertEqual(stored.answers["hero"]?.result, .pass)
        XCTAssertEqual(stored.answers["cta"]?.note, "Below the fold")
        XCTAssertEqual(stored.viewport, "390x844")

        session.next()
        XCTAssertEqual(session.key, "phone.dark")
        XCTAssertNil(session.answer("hero"))
        session.select(key: "desktop.dark")
        XCTAssertEqual(session.size.id, "desktop")
        XCTAssertEqual(session.appearance, .dark)
        XCTAssertFalse(session.hasNext)
        session.previous()
        XCTAssertEqual(session.key, "desktop.light")

        // Taking an answer back.
        session.select(key: "phone.light")
        session.setAnswer("hero", nil)
        XCTAssertNil(session.answer("hero"))
        _ = await session.flush()
        XCTAssertNil(try request(model, "PETS-1-page").checks.first?.results["phone.light"]?.answers["hero"])
    }

    func testTheDecisionWritesWaitingAnswersFirstAndChangesStartsFromWhatFailed() async throws {
        let model = await opened()
        let session = ReviewCheckSession(model: model, ref: try request(model, "PETS-1-page").ref, checkID: "page")
        session.debounce = .seconds(30)
        session.setAnswer("cta", .fail, note: "Below the fold")
        XCTAssertEqual(session.changesDraft, "Phone, light: The download button shows without scrolling — Below the fold")
        let refused = await session.decide(.changesRequested)
        XCTAssertFalse(refused, "Changes needs a message")
        let decided = await session.decide(.changesRequested, comment: session.changesDraft)
        XCTAssertTrue(decided)
        let check = try XCTUnwrap(try request(model, "PETS-1-page").checks.first)
        XCTAssertEqual(check.status, .changesRequested)
        XCTAssertEqual(check.results["phone.light"]?.answers["cta"]?.result, .fail)
        XCTAssertEqual(check.comments.last?.text, "Phone, light: The download button shows without scrolling — Below the fold")
        XCTAssertFalse(try request(model, "PETS-1-page").entries[0].isWaiting)
    }

    func testAScreenshotIsStoredForTheSizeOnScreen() async throws {
        let model = await opened()
        let session = ReviewCheckSession(model: model, ref: try request(model, "PETS-1-page").ref, checkID: "page")
        session.select(key: "desktop.dark")
        session.viewport = "1440x900"
        let saved = await session.saveScreenshot(Data("png".utf8))
        XCTAssertTrue(saved)
        XCTAssertTrue(exists("Pets/review/PETS-1-page/results/page-desktop.dark.png"))
        XCTAssertEqual(session.screenshot, "results/page-desktop.dark.png")
    }

    func testSomeoneElsesCheckCannotBeAnswered() async throws {
        try write("Pets/review/PETS-1-page/review.md", try read("Pets/review/PETS-1-page/review.md")
            .replacingOccurrences(of: "requested_by: claude", with: "requested_by: claude\nfor: herma"))
        let model = await opened()
        let session = ReviewCheckSession(model: model, ref: try request(model, "PETS-1-page").ref, checkID: "page")
        XCTAssertTrue(session.isReadOnly)
        XCTAssertEqual(session.readOnlyNotice, "For Herma. You can comment.")
        XCTAssertFalse(session.setAnswer("hero", .pass))
        XCTAssertNil(session.answer("hero"))
        await session.comment("Looks fine from here")
        XCTAssertEqual(try request(model, "PETS-1-page").checks.first?.comments.map(\.text), ["Looks fine from here"])
    }
}
