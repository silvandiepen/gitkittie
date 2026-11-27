import Foundation
import GitKittieKit

/// The weeks the Mac calendar scrolls through, and which month a position in them shows.
///
/// The calendar is one continuous column of weeks rather than one month at a time: a month
/// sized to the window left nothing to scroll (GITKITTIE-113). It reaches a year either side
/// of today, and further when a task is due further out.
public struct BoardCalendar: Sendable {
    public let calendar: Calendar
    /// The first day of every week shown, oldest first.
    public let weeks: [Date]

    /// How far either side of today the weeks reach when no task is due further out.
    public static let reach = 12

    public init(dueDays: some Sequence<String>, today: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        let dues = dueDays.compactMap(CardDates.date)
        let earliest = [calendar.date(byAdding: .month, value: -Self.reach, to: today) ?? today, dues.min()].compactMap { $0 }.min() ?? today
        let latest = [calendar.date(byAdding: .month, value: Self.reach, to: today) ?? today, dues.max()].compactMap { $0 }.max() ?? today
        // Whole months, so the first and last month on screen are complete.
        let from = calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest
        let through = calendar.dateInterval(of: .month, for: latest)?.end ?? latest
        guard let first = calendar.dateInterval(of: .weekOfYear, for: from)?.start else { weeks = []; return }
        var out: [Date] = []
        var week = first
        while week < through {
            out.append(week)
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week), next > week else { break }
            week = next
        }
        weeks = out
    }

    /// The first day of the week holding `day`.
    public func week(of day: Date) -> Date? {
        calendar.dateInterval(of: .weekOfYear, for: day)?.start
    }

    /// The week to put at the top to show the month holding `day`: the week of its first day.
    public func topWeek(forMonthOf day: Date) -> Date? {
        guard let start = calendar.dateInterval(of: .month, for: day)?.start else { return nil }
        return week(of: start)
    }

    /// The month the screen shows when `top` is the top week: the month two weeks further on,
    /// so a top row that still ends the month before does not name it.
    public func month(atTop top: Date) -> Date {
        let middle = calendar.date(byAdding: .day, value: 14, to: top) ?? top
        return calendar.dateInterval(of: .month, for: middle)?.start ?? middle
    }

    /// The top week for the month `months` away from the one shown.
    public func topWeek(stepping months: Int, from top: Date) -> Date? {
        guard let month = calendar.date(byAdding: .month, value: months, to: month(atTop: top)) else { return nil }
        return topWeek(forMonthOf: month)
    }

    /// The seven days of a week.
    public func days(of week: Date) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
    }
}
