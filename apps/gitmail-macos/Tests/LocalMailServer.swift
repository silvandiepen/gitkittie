import Foundation
import MailAccounts
import MailCore
import MailProvider
import XCTest

/// The local GreenMail from `swift/GitKittieMailProviders/scripts/test-mail-server.sh start`,
/// for the app model's account tests. Tests that need it skip when it is not running, unless
/// `GKM_REQUIRE_TEST_MAIL_SERVER=1` (CI), where a missing server fails.
struct LocalMailServer {
    struct User {
        let address: String
        let password: String
    }

    let caPEM: Data
    let imapsPort = 3993
    let smtpsPort = 3465
    let apiPort = 3080

    var trust: TrustPolicy { .customRoots(pem: [caPEM]) }

    static func require() async throws -> LocalMailServer {
        let environment = ProcessInfo.processInfo.environment
        let state = environment["GKM_TEST_MAIL_SERVER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/GitKittieMail/test-mail-server")
        let server = (try? Data(contentsOf: state.appendingPathComponent("tls/ca.pem"))).map { LocalMailServer(caPEM: $0) }
        guard let server, await server.isRunning() else {
            if environment["GKM_REQUIRE_TEST_MAIL_SERVER"] == "1" { throw MissingLocalMailServer() }
            throw XCTSkip("The local test mail server is not running (swift/GitKittieMailProviders/scripts/test-mail-server.sh start).")
        }
        return server
    }

    private func isRunning() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(apiPort)/api/configuration")!)
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    /// A fresh synthetic account on example.com.
    func makeUser() async throws -> User {
        let address = "app-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let password = "pw-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(apiPort)/api/user")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": address, "login": address, "password": password])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw XCTSkip("could not create a test user") }
        return User(address: address, password: password)
    }

    /// Puts synthetic messages in the user's inbox, oldest first.
    func append(_ subjects: [String], for user: User) async throws {
        let connections = AccountConnections(trust: trust)
        let settings = MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "localhost", port: imapsPort, security: .implicitTLS, username: user.address),
            smtp: MailServerSettings(host: "localhost", port: smtpsPort, security: .implicitTLS, username: user.address))
        try await connections.imap(settings, password: Secret(user.password)).withSession { session in
            for (index, subject) in subjects.enumerated() {
                let raw = "From: Bo <bo@example.net>\r\nTo: \(user.address)\r\nSubject: \(subject)\r\nMessage-ID: <\(UUID().uuidString)@example.net>\r\nDate: Tue, 24 Nov 2026 0\(index % 10):00:00 +0000\r\n\r\n\(subject) body.\r\n"
                _ = try await session.append(Data(raw.utf8), to: "INBOX", flags: MessageFlags())
            }
        }
    }
}

struct MissingLocalMailServer: Error, CustomStringConvertible {
    var description: String { "GKM_REQUIRE_TEST_MAIL_SERVER=1 but the local test mail server is not running" }
}
