import CryptoKit
import Foundation
import GitKittieKit

// Push notifications for review requests, the app's side of the relay
// (`apps/gitkanban-relay`, docs/Push.md there).
//
// - A GitHub board: the "GitKittie Tasks" GitHub App sends the relay every push of a repo it
//   is installed on. The device registers for the repo with the relay, sending the person's
//   own token once so the relay can check with GitHub that they may read the repo. When the
//   App is not installed there yet, the relay answers with the page to install it on.
// - A GitLab board: the relay cannot read its files, so it wakes the app when a review
//   changes and the app looks for itself. The device registers on the repo's live-updates
//   channel (`.gitkanban/relay.json`), which proves it can read the repo.
//
// The app never calls GitHub or GitLab for this itself: the relay holds the App and builds
// the install page's address.

/// What a push about a review says (the `review` object of its payload).
public struct PushedReview: Equatable, Sendable {
    /// `owner/name`: an added repo's id.
    public var repo: String
    /// The request's folder, `Morrow/review/MORROW-182-pet-models`.
    public var folder: String
    public var id: String
    public var board: String
    public var level: ReviewNotify

    public init(repo: String, folder: String, id: String, board: String, level: ReviewNotify) {
        self.repo = repo; self.folder = folder; self.id = id; self.board = board; self.level = level
    }

    /// The review a notification's payload names, or `nil` when it names none.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let review = userInfo["review"] as? [String: Any],
              let repo = review["repo"] as? String, let folder = review["folder"] as? String else { return nil }
        self.init(repo: repo, folder: folder, id: review["id"] as? String ?? folder,
                  board: review["board"] as? String ?? "", level: ReviewNotify(parsing: review["level"] as? String))
    }

    /// The request this is about, as the app tells requests apart.
    public var ref: ReviewRef { ReviewRef(origin: repo, folder: folder) }
}

/// The notification identifier both a push (its `apns-collapse-id`) and the app's own check
/// use for a request, so a request is shown once however it was noticed:
/// `review-` + 32 hex of SHA-256("<repo>|<folder>"). Same as `collapseID` in the relay.
public func reviewNotificationID(repo: String, folder: String) -> String {
    let digest = SHA256.hash(data: Data("\(repo)|\(folder)".utf8))
    return "review-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
}

/// A device as the relay keeps it.
struct PushDevice: Encodable, Equatable {
    var token: String
    var platform: String
    var environment: String
    var levels: [String]
    var appVersion: String
}

enum PushRelay {
    /// What registering for a GitHub repo came to.
    enum GitHubOutcome: Equatable {
        case registered(repoID: Int)
        /// The GitHub App is not installed on the repo: this page installs it there.
        case notInstalled(URL)
        /// The person's account cannot read the repo, or the relay refused.
        case refused(String)
    }

    private struct Answer: Decodable {
        var repoID: Int?
        var installURL: String?
        var error: String?
    }

    static func registerGitHub(relay: URL, repo: String, userToken: String, device: PushDevice, clientID: String) async throws -> GitHubOutcome {
        struct Body: Encodable { var repo: String; var device: PushDevice }
        let body = try JSONEncoder().encode(Body(repo: repo, device: device))
        var request = URLRequest(url: relay.appendingPathComponent("github/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        request.setValue(RelayClientProof.header(clientID: clientID, body: body), forHTTPHeaderField: RelayClientProof.headerName)
        request.httpBody = body
        let (data, response) = try await UncachedHTTPClient.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = try? JSONDecoder().decode(Answer.self, from: data)
        switch status {
        case 201:
            guard let repoID = answer?.repoID else { return .refused("The relay gave no repository id.") }
            return .registered(repoID: repoID)
        case 409:
            guard let address = answer?.installURL, let url = URL(string: address), url.scheme == "https" else {
                return .refused("The relay did not say where to install GitKittie Tasks.")
            }
            return .notInstalled(url)
        case 403:
            return .refused("This account cannot read \(repo).")
        case 401:
            return .refused("The relay did not recognise this app. Check that this device's clock is right.")
        case 503:
            return .refused("Instant notifications are not set up on the relay yet.")
        default:
            return .refused(answer?.error ?? "The relay answered \(status).")
        }
    }

    static func unregisterGitHub(relay: URL, repoID: Int, token: String) async {
        struct Body: Encodable { var repoID: Int; var token: String }
        var request = URLRequest(url: relay.appendingPathComponent("github/devices"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Body(repoID: repoID, token: token))
        _ = try? await UncachedHTTPClient.session.data(for: request)
    }

    private static func channelURL(_ config: RelayConfig) -> URL? {
        guard var components = URLComponents(string: config.relay) else { return nil }
        components.path = "/channels/\(config.channel)/devices"
        return components.url
    }

    static func registerChannel(_ config: RelayConfig, device: PushDevice, clientID: String) async throws {
        struct Body: Encodable { var key: String; var device: PushDevice }
        guard let url = channelURL(config) else { throw BoardSourceError(message: "The repo's relay address is not valid.") }
        let body = try JSONEncoder().encode(Body(key: config.subscribeKey, device: device))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RelayClientProof.header(clientID: clientID, body: body), forHTTPHeaderField: RelayClientProof.headerName)
        request.httpBody = body
        let (_, response) = try await UncachedHTTPClient.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else { throw BoardSourceError(message: "The relay did not register this device (\(status)).") }
    }

    static func unregisterChannel(_ config: RelayConfig, token: String) async {
        struct Body: Encodable { var key: String; var token: String }
        guard let url = channelURL(config) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Body(key: config.subscribeKey, token: token))
        _ = try? await UncachedHTTPClient.session.data(for: request)
    }
}

extension PushedReview {
    /// The payload's `review` object, for a notification the app posts itself.
    var userInfo: [AnyHashable: Any] {
        ["review": ["repo": repo, "folder": folder, "id": id, "board": board, "level": level.rawValue]]
    }
}
