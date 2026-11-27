import Foundation

/// A new task another app asks Tasks to start, as a URL:
/// `gitkittie-tasks://new?title=<text>&body=<Markdown>` (GitKittie Mail's Make Task, GKM-033).
///
/// It only fills in the new-task sheet: the person sees the title and description, picks the
/// board and lane, and presses Create. Nothing is ever written from a URL alone, because any
/// app or web page can open one. Tasks knows nothing about where a request came from: the
/// sender puts its own link (Mail's `gitkittie-mail://message/…`) in the body, as Markdown.
public struct NewTaskRequest: Equatable, Sendable {
    public static let scheme = "gitkittie-tasks"
    public static let host = "new"
    /// Longer titles are cut here: a card title is a line, not a document.
    public static let maximumTitleLength = 300
    /// Longer descriptions are cut here, so a URL cannot fill a card with megabytes.
    public static let maximumBodyLength = 10_000

    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = Self.clean(title, singleLine: true, limit: Self.maximumTitleLength)
        self.body = Self.clean(body, singleLine: false, limit: Self.maximumBodyLength)
    }

    /// The request a URL carries; `nil` for any other URL, and for one with neither a title
    /// nor a description.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        self.init(title: value("title"), body: value("body"))
        guard !title.isEmpty || !body.isEmpty else { return nil }
    }

    /// The URL that asks Tasks for this request.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        // `+` is a space to some form decoders; Foundation leaves it as is, so encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// What the new-task sheet holds once this request reaches it: an empty title takes the
    /// request's; the description gets the request's below what is already there. What the
    /// person typed is never replaced.
    public func filling(title current: String, body currentBody: String) -> (title: String, body: String) {
        let keptTitle = current.trimmingCharacters(in: .whitespaces).isEmpty ? title : current
        let existing = currentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let newBody = body.isEmpty ? currentBody : existing.isEmpty ? body : existing + "\n\n" + body
        return (keptTitle, newBody)
    }

    /// Control characters out (a title also turns its line breaks into spaces), white space trimmed, and
    /// cut at `limit` Characters.
    private static func clean(_ text: String, singleLine: Bool, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                scalars.append(singleLine ? " " : scalar)
            } else if scalar == "\r" {
                if singleLine { scalars.append(" ") }
            } else if scalar.properties.generalCategory != .control {
                // Only Cc: format characters (Cf) such as the joiner in 👩‍💻 stay.
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }
}
