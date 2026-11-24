import Foundation

/// Dates and sizes as the window shows them. The store keeps UTC instants; this is the one
/// place they become local, readable text.
enum MessageDate {
    /// Today: the time. This year: day and month. Older: the date with its year.
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func long(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }

    static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
