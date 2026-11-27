import Foundation
import MailCore
import MailStore

/// What waits for the store to open: a notification's message, or a message link (GKM-033).
enum PendingOpen: Equatable {
    case message(MailMessageID)
    case link(MessageLink)
}

/// Make Task (GKM-033, MAIL-132): the URL that asks GitKittie Tasks for a new task about a
/// message. Tasks only fills in its new-task sheet from it; the person picks the board and
/// presses Create there, so nothing reaches a board (or the Git repository behind it) unseen.
///
/// The contract is Tasks' `NewTaskRequest` (swift/GitKanbanKit): `gitkittie-tasks://new` with
/// `title` and `body` query items, `+` written as `%2B`. Mail does not import Tasks' code
/// (apps never import each other), so the URL is built here, to the same shape.
///
/// What goes in is the least that makes the task useful: the subject as the title, and in
/// the description who it is from (their name, else the address), the day, and the stable
/// link back to the message. Never the message's text or attachments (MAIL-132).
struct TaskHandoff: Equatable {
    static let scheme = "gitkittie-tasks"
    /// What the person is told when no app takes the link.
    static let notInstalled = "Make Task needs GitKittie Tasks. Install it, then try again."

    var title: String
    var body: String

    init(subject: String?, from: MailAddress?, date: Date, link: MessageLink,
         timeZone: TimeZone = .current, locale: Locale = .current) {
        let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sender = from?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = !subject.isEmpty ? subject : sender.isEmpty ? "Message" : "Message from \(sender)"
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)
        style.timeZone = timeZone
        let day = date.formatted(style)
        let who = sender.isEmpty ? "Mail" : "From \(sender)"
        body = "\(who), \(day).\n\n[Open in Mail](\(link.url.absoluteString))"
    }

    /// `gitkittie-tasks://new?title=…&body=…`.
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "new"
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

extension AppModel {
    /// The stable link to a message (GKM-033, MAIL-131), for Copy Link and Make Task.
    func link(to id: MailMessageID) async -> MessageLink? {
        guard let store = mailStore else { return nil }
        do {
            guard let link = try await store.link(to: id) else {
                actionError = "That message is no longer on \(DeviceWords.this)."
                return nil
            }
            return link
        } catch {
            actionError = String(describing: error)
            return nil
        }
    }

    /// Make Task: the `gitkittie-tasks://new` URL for a message, for the view to open. `nil`,
    /// with `actionError` set, when the message is not in the store.
    func taskHandoff(for id: MailMessageID, timeZone: TimeZone = .current, locale: Locale = .current) async -> TaskHandoff? {
        guard let store = mailStore, let link = await link(to: id) else { return nil }
        do {
            guard let summary = try await store.summary(of: id) else { return nil }
            return TaskHandoff(subject: summary.subject, from: summary.from, date: summary.date, link: link,
                               timeZone: timeZone, locale: locale)
        } catch {
            actionError = String(describing: error)
            return nil
        }
    }

    /// A `gitkittie-mail://message/…` link was opened (from a Tasks card, a note, anywhere):
    /// show that message's conversation as a notification does. Before the store is open it
    /// waits for it. False for a URL that is not a message link.
    @discardableResult
    func openLink(_ url: URL) async -> Bool {
        guard let link = MessageLink(url: url) else {
            actionError = "That isn't a link to a message."
            return false
        }
        await open(link)
        return true
    }

    func open(_ link: MessageLink) async {
        guard phase == .ready, let store = mailStore else {
            pendingOpen = .link(link)
            return
        }
        do {
            guard let id = try await store.resolve(link) else {
                actionError = "That message isn't on \(DeviceWords.this). It may have been deleted, or not downloaded here."
                return
            }
            await openFromNotification(id)
        } catch {
            actionError = String(describing: error)
        }
    }
}
