import Foundation
import GitKittieKit

// Live updates through the GitKanban relay (`apps/gitkanban-relay`).
//
// A repo that has live updates turned on carries `.gitkanban/relay.json`: which relay,
// which channel, and the key to subscribe with. Whoever can read the repo can read that
// file and subscribe; the relay never sees a git token. The relay sends "these paths
// changed" when GitHub or GitLab delivers a push webhook, and the board reloads what they
// touch. Only GitKittie clients register a channel: each install sends its own random id
// and the family hash (`RelayClientProof` in GitKittieKit).

/// A repo's relay channel, as committed to the repo.
public struct RelayConfig: Codable, Equatable, Sendable {
    /// Where the file lives, relative to the repo root.
    public static let path = ".gitkanban/relay.json"

    /// The relay's base URL, e.g. `https://gitkanban-relay.example.workers.dev`.
    public var relay: String
    public var channel: String
    public var subscribeKey: String
    /// The id of the webhook on the provider, kept so it can be removed again.
    public var hookID: Int?

    var socketURL: URL? {
        guard var components = URLComponents(string: relay) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/channels/\(channel)/socket"
        components.queryItems = [URLQueryItem(name: "key", value: subscribeKey)]
        return components.url
    }
}

enum RelayClient {
    /// What the relay returns when a channel is registered.
    struct Registration: Decodable {
        let channel: String
        let hookSecret: String
        let subscribeKey: String
        let hookURL: String
    }

    /// The path that stands for "anything may have changed": reload rather than patch.
    static let everything = "*"

    static func register(relay: URL, repo: String, clientID: String) async throws -> Registration {
        var request = URLRequest(url: relay.appendingPathComponent("channels"))
        let body = try JSONEncoder().encode(["repo": repo])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RelayClientProof.header(clientID: clientID, body: body),
                         forHTTPHeaderField: RelayClientProof.headerName)
        request.httpBody = body
        let (data, response) = try await UncachedHTTPClient.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else {
            throw BoardSourceError(message: status == 401
                ? "The relay did not recognise this app. Check that this device's clock is right and that the relay is up to date."
                : "The relay did not register a channel (\(status)).")
        }
        return try JSONDecoder().decode(Registration.self, from: data)
    }

    static func remove(_ config: RelayConfig) async {
        guard var components = URLComponents(string: config.relay) else { return }
        components.path = "/channels/\(config.channel)"
        components.queryItems = [URLQueryItem(name: "key", value: config.subscribeKey)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await UncachedHTTPClient.session.data(for: request)
    }

    private struct Event: Decodable {
        let type: String
        let ref: String?
        let paths: [String]?
        let complete: Bool?
    }

    /// The paths a relay message says changed on `branch`; `nil` when it is not about it.
    static func paths(in message: String, branch: String) -> [String]? {
        guard let event = try? JSONDecoder().decode(Event.self, from: Data(message.utf8)),
              event.type == "push", event.ref == "refs/heads/\(branch)" else { return nil }
        guard event.complete == true, let paths = event.paths, !paths.isEmpty else { return [everything] }
        return paths
    }

    /// Changed paths on `branch`, for as long as the stream is held. The connection is kept
    /// alive and re-made when it drops; after a re-connect `everything` is reported once,
    /// since pushes may have been missed while it was down.
    static func changes(_ config: RelayConfig, branch: String) -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let task = Task {
                guard let url = config.socketURL else { continuation.finish(); return }
                var delay: UInt64 = 1_000_000_000
                var connectedBefore = false
                while !Task.isCancelled {
                    let socket = URLSession.shared.webSocketTask(with: url)
                    socket.resume()
                    let keepAlive = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 25_000_000_000)
                            try? await socket.send(.string("ping"))
                        }
                    }
                    do {
                        while !Task.isCancelled {
                            guard case .string(let text) = try await socket.receive() else { continue }
                            if text.contains("\"hello\"") {
                                delay = 1_000_000_000
                                if connectedBefore { continuation.yield([everything]) }
                                connectedBefore = true
                            } else if let paths = paths(in: text, branch: branch) {
                                continuation.yield(paths)
                            }
                        }
                    } catch {
                        // Dropped or refused: wait, then connect again.
                    }
                    keepAlive.cancel()
                    socket.cancel(with: .goingAway, reason: nil)
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, 30_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension OutboxSource: ChangeObservingSource {
    /// Live changes for a repo that has a relay channel; an empty stream for one that has none.
    func changes() -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let task = Task {
                guard let text = try? await readText(RelayConfig.path),
                      let config = try? JSONDecoder().decode(RelayConfig.self, from: Data(text.utf8)) else {
                    continuation.finish()
                    return
                }
                for await paths in RelayClient.changes(config, branch: branch) { continuation.yield(paths) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
