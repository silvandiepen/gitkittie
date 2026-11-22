import Foundation

/// The `## Activity log` of a task: what happened to it, one entry per line. Agents and
/// people both write to it; the apps show it apart from the description.
public enum CardActivity {

    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: Int
        /// When, as written (`2026-11-22T10:00:00Z` or `2026-11-22`); nil when the line has no date.
        public var stamp: String?
        public var author: String?
        public var text: String

        public var date: Date? { stamp.flatMap(CardDates.date) }
    }

    /// A task's text in two parts: what is written about it, and its activity log. The log
    /// is only taken apart when it is the last section, which is where it is written.
    public static func split(_ body: String) -> (notes: String, log: String) {
        let lines = body.components(separatedBy: "\n")
        guard let heading = lines.lastIndex(where: isHeading),
              !lines[(heading + 1)...].contains(where: { $0.hasPrefix("## ") || $0.hasPrefix("# ") }) else {
            return (body.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let notes = lines[..<heading].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let log = lines[heading...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (notes, log)
    }

    /// Put the two parts back together.
    public static func join(notes: String, log: String) -> String {
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !log.isEmpty else { return notes }
        return notes.isEmpty ? log : notes + "\n\n" + log
    }

    /// The entries of a task's activity log, oldest first.
    public static func entries(in body: String) -> [Entry] {
        let lines = body.components(separatedBy: "\n")
        guard let heading = lines.lastIndex(where: isHeading) else { return [] }
        var entries: [Entry] = []
        for line in lines[(heading + 1)...] {
            if line.hasPrefix("## ") || line.hasPrefix("# ") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                entries.append(entry(String(trimmed.dropFirst(2)), id: entries.count))
            } else if !trimmed.isEmpty, !entries.isEmpty, line.first?.isWhitespace == true {
                // A wrapped line belongs to the entry above it.
                entries[entries.count - 1].text += " " + trimmed
            }
        }
        return entries
    }

    /// How many entries a task has, without building them.
    public static func count(in body: String) -> Int {
        guard body.range(of: "## activity log", options: .caseInsensitive) != nil else { return 0 }
        return entries(in: body).count
    }

    /// One line for the log: `2026-11-22T10:00:00Z — `sil` text`.
    public static func line(author: String, text: String, at date: Date = Date()) -> String {
        "\(Review.timestamp(date)) — `\(author)` \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private static func isHeading(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).lowercased() == "## activity log"
    }

    private static func entry(_ raw: String, id: Int) -> Entry {
        var rest = Substring(raw)
        var stamp: String?
        // A leading date, with or without a time.
        let token = rest.prefix { !$0.isWhitespace }
        let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: ":,"))
        if bare.count >= 10, CardDates.date(bare) != nil {
            stamp = bare
            rest = rest.dropFirst(token.count)
        }
        rest = rest.drop { $0.isWhitespace || $0 == "—" || $0 == "–" || $0 == "-" || $0 == ":" }
        var author: String?
        if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
            author = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
        } else if stamp != nil, let colon = rest.firstIndex(of: ":"),
                  rest[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), rest[..<colon].count <= 24 {
            // `2026-11-22 claude: text`
            author = String(rest[..<colon])
            rest = rest[rest.index(after: colon)...]
        }
        rest = rest.drop { $0.isWhitespace || $0 == ":" || $0 == "—" || $0 == "–" }
        return Entry(id: id, stamp: stamp, author: author, text: String(rest))
    }
}

/// Dates as tasks write them: a day (`2026-11-24`) or a moment (`2026-11-22T10:00:00Z`).
public enum CardDates {
    public static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.count == 10 { return dayFormatter.date(from: text) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        return text.count > 10 ? dayFormatter.date(from: String(text.prefix(10))) : nil
    }

    /// A day as a task stores it.
    public static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// "Nov 24", with the year when it is not this one or when asked for.
    public static func short(_ text: String?, year: Bool = false) -> String? {
        guard let text, let date = date(text) else { return nil }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
        return date.formatted(year || !sameYear ? .dateTime.month(.abbreviated).day().year() : .dateTime.month(.abbreviated).day())
    }

    /// Days are days in the reader's own calendar, not moments in UTC.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
