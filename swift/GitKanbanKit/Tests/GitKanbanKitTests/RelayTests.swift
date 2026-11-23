import CryptoKit
import GitKittieKit
import GitPontCore
import XCTest
@testable import GitKanbanKit

final class RelayTests: XCTestCase {
    func testOnlyPushesToTheReposBranchCount() {
        let push = #"{"type":"push","ref":"refs/heads/main","head":"abc","paths":["Tasks/Pets/1. To do/a.md"],"complete":true}"#
        XCTAssertEqual(RelayClient.paths(in: push, branch: "main"), ["Tasks/Pets/1. To do/a.md"])
        XCTAssertNil(RelayClient.paths(in: push, branch: "develop"))
        XCTAssertNil(RelayClient.paths(in: #"{"type":"hello","repo":"o/r"}"#, branch: "main"))
        XCTAssertNil(RelayClient.paths(in: "pong", branch: "main"))
    }

    func testAnIncompletePushMeansReloadEverything() {
        let forced = #"{"type":"push","ref":"refs/heads/main","head":"abc","paths":["a.md"],"complete":false}"#
        XCTAssertEqual(RelayClient.paths(in: forced, branch: "main"), [RelayClient.everything])
        let empty = #"{"type":"push","ref":"refs/heads/main","head":"abc","paths":[],"complete":true}"#
        XCTAssertEqual(RelayClient.paths(in: empty, branch: "main"), [RelayClient.everything])
    }

    func testSocketURLCarriesChannelAndKey() {
        let config = RelayConfig(relay: "https://relay.example.dev", channel: "abc", subscribeKey: "k", hookID: 7)
        XCTAssertEqual(config.socketURL?.absoluteString, "wss://relay.example.dev/channels/abc/socket?key=k")
        let local = RelayConfig(relay: "http://127.0.0.1:8787", channel: "abc", subscribeKey: "k", hookID: nil)
        XCTAssertEqual(local.socketURL?.absoluteString, "ws://127.0.0.1:8787/channels/abc/socket?key=k")
    }

    func testEachInstallKeepsItsOwnRandomClientID() throws {
        let suite = "relay-client-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = RelayClientProof.clientID(in: defaults)
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertEqual(RelayClientProof.clientID(in: defaults), id)
        let other = try XCTUnwrap(UserDefaults(suiteName: suite + "-b"))
        defer { other.removePersistentDomain(forName: suite + "-b") }
        XCTAssertNotEqual(RelayClientProof.clientID(in: other), id)
    }

    func testTheProofCarriesTheIDTheTimeAndAHashOfTheRequest() {
        let body = Data(#"{"repo":"octo/board"}"#.utf8)
        let id = "0123456789abcdef0123456789abcdef"
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let header = RelayClientProof.header(clientID: id, body: body, time: time)
        XCTAssertNotNil(header.range(of: "^id=\(id),t=1800000000,v1=[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertNotEqual(header, RelayClientProof.header(clientID: id, body: Data("{}".utf8), time: time))
        XCTAssertNotEqual(header.suffix(64), RelayClientProof.header(clientID: String(repeating: "f", count: 32), body: body, time: time).suffix(64))
    }

    /// The requests themselves are git-pont's and tested there; here only the split of a
    /// repo's full name, which GitLab subgroups make more than two parts.
    func testWebhookRepositoryReferenceKeepsSubgroups() {
        let nested = ProviderWebhook.reference(.gitLabCloud, "group/sub/board")
        XCTAssertEqual(nested.namespace, "group/sub")
        XCTAssertEqual(nested.name, "board")
        let plain = ProviderWebhook.reference(.github, "octo/board")
        XCTAssertEqual(plain.namespace, "octo")
        XCTAssertEqual(plain.name, "board")
    }

    /// Against a running relay (`RELAY_URL=http://127.0.0.1:8787`, e.g. `wrangler dev`):
    /// a client with a fresh random id registers (so the app and the relay agree on the
    /// family hash), subscribes, and receives a GitHub-style and a GitLab-style push.
    func testAPushReachesASubscriberThroughARunningRelay() async throws {
        guard let base = ProcessInfo.processInfo.environment["RELAY_URL"], let relay = URL(string: base) else {
            throw XCTSkip("Set RELAY_URL to a running relay")
        }
        do {
            _ = try await RelayClient.register(relay: relay, repo: "octo/board", clientID: "not-a-client-id")
            XCTFail("a malformed client id was accepted")
        } catch let error as BoardSourceError {
            XCTAssertTrue(error.message.contains("did not recognise this app"), error.message)
        }
        let suite = "relay-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = try await RelayClient.register(
            relay: relay, repo: "octo/board", clientID: RelayClientProof.clientID(in: defaults))
        let config = RelayConfig(relay: base, channel: registration.channel, subscribeKey: registration.subscribeKey, hookID: nil)
        let received = expectation(description: "paths arrive")
        let listener = Task {
            var seen: [[String]] = []
            for await paths in RelayClient.changes(config, branch: "main") {
                seen.append(paths)
                if seen.count == 2 { break }
            }
            XCTAssertEqual(seen, [["Tasks/Pets/1. To do/new.md"], ["Tasks/Pets/2. Doing/moved.md"]])
            received.fulfill()
        }
        try await Task.sleep(nanoseconds: 800_000_000)   // let the socket connect

        let body = Data(#"{"ref":"refs/heads/main","after":"abc","commits":[{"added":["Tasks/Pets/1. To do/new.md"]}]}"#.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(registration.hookSecret.utf8)))
        var request = URLRequest(url: try XCTUnwrap(URL(string: registration.hookURL)))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("push", forHTTPHeaderField: "X-GitHub-Event")
        request.setValue("sha256=" + mac.map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "X-Hub-Signature-256")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        // The same change as GitLab delivers it: the secret as a token, no body signature.
        var gitlab = URLRequest(url: try XCTUnwrap(URL(string: registration.hookURL)))
        gitlab.httpMethod = "POST"
        gitlab.httpBody = Data(#"{"object_kind":"push","ref":"refs/heads/main","after":"def","total_commits_count":1,"commits":[{"modified":["Tasks/Pets/2. Doing/moved.md"]}]}"#.utf8)
        gitlab.setValue("Push Hook", forHTTPHeaderField: "X-Gitlab-Event")
        gitlab.setValue(registration.hookSecret, forHTTPHeaderField: "X-Gitlab-Token")
        let (_, gitlabResponse) = try await URLSession.shared.data(for: gitlab)
        XCTAssertEqual((gitlabResponse as? HTTPURLResponse)?.statusCode, 200)

        await fulfillment(of: [received], timeout: 5)
        listener.cancel()
        await RelayClient.remove(config)
    }
}
