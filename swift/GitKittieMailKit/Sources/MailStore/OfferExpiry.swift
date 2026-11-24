import Foundation

/// Finds when an offer ends from its subject and preview text ("Sale ends Sunday", "valid until
/// 30 November", "geldig t/m 3 dec"), read against the date the message was sent (GKM-021).
///
/// Only an end word followed by a date counts, so "Order by 12 Dec for Christmas" or a date in
/// a newsletter's headline is no end date. Numeric dates like 11/12 are ignored: day and month
/// order differ by country and a wrong guess would call a running offer ended. When nothing is
/// found the offer's age decides (Classification.md, Retention).
public enum OfferExpiry {
    /// The last moment of the day the offer ends, in `calendar`'s time zone, or nil.
    public static func endDate(subject: String?, text: String?, sent: Date, calendar: Calendar = Self.calendar) -> Date? {
        for source in [subject, text].compactMap({ $0 }) where !source.isEmpty {
            if let day = endDay(in: source.lowercased(), sent: sent, calendar: calendar) {
                return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: day))
            }
        }
        return nil
    }

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    // MARK: - Reading

    private static let endWords = [
        "ends", "ending", "expires", "expiring", "valid until", "valid till", "valid through", "valid thru",
        "until", "through", "last day", "last chance", "closes", "geldig tot", "geldig t/m", "t/m", "tot en met", "eindigt", "loopt af",
    ]

    private static let months: [(String, Int)] = [
        ("january", 1), ("jan", 1), ("januari", 1), ("february", 2), ("feb", 2), ("februari", 2), ("march", 3), ("mar", 3),
        ("maart", 3), ("mrt", 3), ("april", 4), ("apr", 4), ("may", 5), ("mei", 5), ("june", 6), ("jun", 6), ("juni", 6),
        ("july", 7), ("jul", 7), ("juli", 7), ("august", 8), ("aug", 8), ("augustus", 8), ("september", 9), ("sept", 9),
        ("sep", 9), ("october", 10), ("oct", 10), ("oktober", 10), ("okt", 10), ("november", 11), ("nov", 11),
        ("december", 12), ("dec", 12),
    ]

    private static let weekdays: [(String, Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7),
        ("zondag", 1), ("maandag", 2), ("dinsdag", 3), ("woensdag", 4), ("donderdag", 5), ("vrijdag", 6), ("zaterdag", 7),
    ]

    private static func endDay(in text: String, sent: Date, calendar: Calendar) -> Date? {
        let words = tokens(text)
        guard !words.isEmpty else { return nil }
        var index = 0
        while index < words.count {
            if let length = endWordLength(words, at: index) {
                // The date follows the end word within a few words ("ends this Sunday at midnight").
                let start = index + length
                if let day = date(in: Array(words[start..<min(words.count, start + 5)]), sent: sent, calendar: calendar) { return day }
                index = start
            } else {
                index += 1
            }
        }
        return nil
    }

    /// Words, with `t/m` kept together.
    private static func tokens(_ text: String) -> [String] {
        text.replacingOccurrences(of: "t/m", with: " t/m ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func endWordLength(_ words: [String], at index: Int) -> Int? {
        for phrase in endWords {
            let parts = phrase.split(separator: " ").map(String.init)
            guard index + parts.count <= words.count else { continue }
            if Array(words[index..<index + parts.count]) == parts { return parts.count }
        }
        return nil
    }

    private static func date(in words: [String], sent: Date, calendar: Calendar) -> Date? {
        let sentDay = calendar.startOfDay(for: sent)
        for (offset, word) in words.enumerated() {
            if word == "today" || word == "tonight" || word == "midnight" || word == "vandaag" || word == "vanavond" { return sentDay }
            if word == "tomorrow" || word == "morgen" { return calendar.date(byAdding: .day, value: 1, to: sentDay) }
            if let weekday = weekdays.first(where: { $0.0 == word })?.1 {
                // The next such day from the day it was sent (the same day counts).
                for step in 0..<7 {
                    if let day = calendar.date(byAdding: .day, value: step, to: sentDay), calendar.component(.weekday, from: day) == weekday {
                        return day
                    }
                }
            }
            if let iso = isoDate(word, calendar: calendar) { return iso }
            if let month = month(word) {
                // "November 30" or "November 30 2026"
                if offset + 1 < words.count, let day = dayNumber(words[offset + 1]) {
                    let year = offset + 2 < words.count ? yearNumber(words[offset + 2]) : nil
                    return resolve(day: day, month: month, year: year, sent: sentDay, calendar: calendar)
                }
            }
            if let day = dayNumber(word), offset + 1 < words.count, let month = month(words[offset + 1]) {
                // "30 November" or "30 November 2026"
                let year = offset + 2 < words.count ? yearNumber(words[offset + 2]) : nil
                return resolve(day: day, month: month, year: year, sent: sentDay, calendar: calendar)
            }
        }
        return nil
    }

    private static func month(_ word: String) -> Int? { months.first { $0.0 == word }?.1 }

    /// 1...31, also "30th", "1st".
    private static func dayNumber(_ word: String) -> Int? {
        let digits = word.prefix { $0.isNumber }
        let rest = word.dropFirst(digits.count)
        guard !digits.isEmpty, digits.count <= 2, ["", "st", "nd", "rd", "th", "e"].contains(String(rest)), let value = Int(digits),
              (1...31).contains(value) else { return nil }
        return value
    }

    private static func yearNumber(_ word: String) -> Int? {
        guard word.count == 4, let value = Int(word), (2000...2100).contains(value) else { return nil }
        return value
    }

    private static func isoDate(_ word: String, calendar: Calendar) -> Date? {
        let parts = word.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// A day and month without a year is the first such date from a week before sending on:
    /// "ends 2 Jan" sent on 28 December is next year.
    private static func resolve(day: Int, month: Int, year: Int?, sent: Date, calendar: Calendar) -> Date? {
        if let year {
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        let sentYear = calendar.component(.year, from: sent)
        guard let candidate = calendar.date(from: DateComponents(year: sentYear, month: month, day: day)),
              calendar.component(.day, from: candidate) == day else { return nil }
        let earliest = calendar.date(byAdding: .day, value: -7, to: sent) ?? sent
        return candidate < earliest ? calendar.date(byAdding: .year, value: 1, to: candidate) : candidate
    }
}
