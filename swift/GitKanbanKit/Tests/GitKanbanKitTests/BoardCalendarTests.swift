import XCTest
@testable import GitKanbanKit

/// The weeks the Mac calendar scrolls through (GITKITTIE-113).
final class BoardCalendarTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }()

    private func day(_ text: String) -> Date {
        var components = DateComponents()
        let parts = text.split(separator: "-").map { Int($0)! }
        components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        return calendar.date(from: components)!
    }

    func testReachesAYearEitherSideOfTodayInWholeWeeks() {
        let span = BoardCalendar(dueDays: [], today: day("2026-11-27"), calendar: calendar)
        let first = span.weeks.first!, last = span.weeks.last!
        // Nov 2025 starts on a Saturday: its week starts Monday 27 October.
        XCTAssertEqual(first, day("2025-10-27"))
        XCTAssertLessThan(last, day("2027-12-01"))
        XCTAssertGreaterThanOrEqual(calendar.date(byAdding: .day, value: 7, to: last)!, day("2027-12-01"))
        for (a, b) in zip(span.weeks, span.weeks.dropFirst()) {
            XCTAssertEqual(calendar.dateComponents([.day], from: a, to: b).day, 7)
            XCTAssertEqual(calendar.component(.weekday, from: a), 2)
        }
    }

    func testReachesFurtherForATaskDueFurtherOut() {
        let span = BoardCalendar(dueDays: ["2024-03-15", "2029-06-02", "not a date"], today: day("2026-11-27"), calendar: calendar)
        XCTAssertLessThanOrEqual(span.weeks.first!, day("2024-03-01"))
        XCTAssertGreaterThanOrEqual(calendar.date(byAdding: .day, value: 7, to: span.weeks.last!)!, day("2029-07-01"))
    }

    func testTheMonthOnScreenIsNotTheOneTheTopRowEnds() {
        let span = BoardCalendar(dueDays: [], today: day("2026-11-27"), calendar: calendar)
        // December 2026 starts on a Tuesday: its first week starts Monday 30 November.
        let top = span.topWeek(forMonthOf: day("2026-12-18"))!
        XCTAssertEqual(top, day("2026-11-30"))
        XCTAssertEqual(span.month(atTop: top), day("2026-12-01"))
        XCTAssertTrue(span.weeks.contains(top))
    }

    func testSteppingAMonthLandsOnThatMonthsFirstWeek() {
        let span = BoardCalendar(dueDays: [], today: day("2026-11-27"), calendar: calendar)
        let november = span.topWeek(forMonthOf: day("2026-11-27"))!
        XCTAssertEqual(november, day("2026-10-26"))
        XCTAssertEqual(span.month(atTop: november), day("2026-11-01"))
        let december = span.topWeek(stepping: 1, from: november)!
        XCTAssertEqual(december, day("2026-11-30"))
        XCTAssertEqual(span.topWeek(stepping: -1, from: december), november)
        XCTAssertEqual(span.topWeek(stepping: -1, from: november), day("2026-09-28"))
        XCTAssertEqual(span.days(of: december).map { calendar.component(.day, from: $0) }, [30, 1, 2, 3, 4, 5, 6])
    }
}
