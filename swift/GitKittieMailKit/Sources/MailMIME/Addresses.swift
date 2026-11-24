import Foundation
import MailCore

/// RFC 5322 address lists: `"Doe, Jane" <jane@example.com>, bob@example.org (Bob)`,
/// groups (`Team: a@example.com, b@example.com;`) and RFC 2047 display names.
public enum AddressParser {
    public static func parseList(_ raw: String) -> [MailAddress] {
        var addresses: [MailAddress] = []
        for item in splitTopLevel(raw) {
            var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            // Group syntax: "display-name: mailbox-list;" — keep the members.
            if let colon = indexOutsideQuotesAndAngles(of: ":", in: text), !text.hasPrefix("<") {
                text = String(text[text.index(after: colon)...])
                for member in splitTopLevel(text.replacingOccurrences(of: ";", with: "")) {
                    if let address = parseMailbox(member) { addresses.append(address) }
                }
                continue
            }
            if let address = parseMailbox(text) { addresses.append(address) }
        }
        return addresses
    }

    public static func parseMailbox(_ raw: String) -> MailAddress? {
        let withoutComments = stripComments(raw)
        let text = withoutComments.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            let address = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = text[text.startIndex..<open].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = ParameterizedValue.unquote(String(name.dropFirst().dropLast()))
            }
            name = EncodedWords.decode(name)
            guard !address.isEmpty else { return nil }
            return MailAddress(name: name.isEmpty ? nil : name, address: address)
        }
        // A bare address; a comment may carry the name ("bob@example.org (Bob)").
        let address = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? text
        guard address.contains("@") else { return nil }
        let name = withoutComments.comment.map { EncodedWords.decode($0) }
        return MailAddress(name: name?.isEmpty == false ? name : nil, address: address)
    }

    /// Splits on commas that are not inside quotes, angle brackets or comments.
    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false, escaped = false
        var angle = 0, comment = 0
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            switch character {
            case "\\" where inQuotes || comment > 0: escaped = true
            case "\"" where comment == 0: inQuotes.toggle()
            case "<" where !inQuotes && comment == 0: angle += 1
            case ">" where !inQuotes && comment == 0: angle = max(0, angle - 1)
            case "(" where !inQuotes: comment += 1
            case ")" where !inQuotes: comment = max(0, comment - 1)
            case "," where !inQuotes && angle == 0 && comment == 0:
                parts.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        parts.append(current)
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func indexOutsideQuotesAndAngles(of target: Character, in text: String) -> String.Index? {
        var inQuotes = false, angle = 0
        for index in text.indices {
            let character = text[index]
            if character == "\"" { inQuotes.toggle() }
            else if character == "<" && !inQuotes { angle += 1 }
            else if character == ">" && !inQuotes { angle -= 1 }
            else if character == target && !inQuotes && angle == 0 { return index }
        }
        return nil
    }

    private static func stripComments(_ text: String) -> (text: String, comment: String?) {
        var out = ""
        var comment = ""
        var depth = 0, inQuotes = false
        for character in text {
            if character == "\"" && depth == 0 { inQuotes.toggle() }
            if !inQuotes && character == "(" { depth += 1; if depth == 1 { continue } }
            if !inQuotes && character == ")" && depth > 0 { depth -= 1; if depth == 0 { continue } }
            if depth > 0 { comment.append(character) } else { out.append(character) }
        }
        let trimmed = comment.trimmingCharacters(in: .whitespaces)
        return (out, trimmed.isEmpty ? nil : trimmed)
    }

    /// Formats an address for a header, quoting and encoding the name as needed.
    public static func format(_ address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.address }
        let display: String
        if name.unicodeScalars.contains(where: { !$0.isASCII }) {
            display = EncodedWords.encodeIfNeeded(name)
        } else if name.rangeOfCharacter(from: CharacterSet(charactersIn: "()<>[]:;@\\,.\"")) != nil {
            display = "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        } else {
            display = name
        }
        return "\(display) <\(address.address)>"
    }
}

/// RFC 5322 3.3 dates, including obsolete zone names and a missing day of week.
public enum MailDates {
    private static let zones: [String: Int] = [
        "UT": 0, "GMT": 0, "Z": 0, "EST": -5 * 60, "EDT": -4 * 60, "CST": -6 * 60, "CDT": -5 * 60,
        "MST": -7 * 60, "MDT": -6 * 60, "PST": -8 * 60, "PDT": -7 * 60,
    ]
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    public static func parse(_ raw: String) -> Date? {
        var text = raw
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        if let comma = text.firstIndex(of: ",") { text = String(text[text.index(after: comma)...]) }
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 4,
              let day = Int(tokens[0]),
              let monthIndex = months.firstIndex(of: String(tokens[1].prefix(3)).lowercased()),
              var year = Int(tokens[2])
        else { return nil }
        if year < 50 { year += 2000 } else if year < 1000 { year += 1900 }
        let timeParts = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard timeParts.count >= 2 else { return nil }
        var offsetMinutes = 0
        if tokens.count >= 5 {
            let zone = tokens[4]
            if let sign = zone.first, sign == "+" || sign == "-", let value = Int(zone.dropFirst()), zone.count == 5 {
                offsetMinutes = (value / 100 * 60 + value % 100) * (sign == "-" ? -1 : 1)
            } else {
                offsetMinutes = zones[zone.uppercased()] ?? 0
            }
        }
        var components = DateComponents()
        components.year = year
        components.month = monthIndex + 1
        components.day = day
        components.hour = timeParts[0]
        components.minute = timeParts[1]
        components.second = timeParts.count > 2 ? timeParts[2] : 0
        components.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60)
        return Calendar(identifier: .gregorian).date(from: components)
    }

    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
