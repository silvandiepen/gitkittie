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
        // In the iOS Simulator the home folder is the app's container; the server's state is in
        // the Mac's home, which the simulator names in SIMULATOR_HOST_HOME (loopback is shared).
        let home = environment["SIMULATOR_HOST_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let state = environment["GKM_TEST_MAIL_SERVER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/GitKittieMail/test-mail-server")
        let server = (try? Data(contentsOf: state.appendingPathComponent("tls/ca.pem"))).map { LocalMailServer(caPEM: $0) }
        guard let server, await server.isRunning() else {
            if environment["GKM_REQUIRE_TEST_MAIL_SERVER"] == "1" { throw MissingLocalMailServer() }
            throw XCTSkip("The local test mail server is not running (swift/GitKittieMailProviders/scripts/test-mail-server.sh start).")
        }
        return server
    }

    /// Asks the admin API a few times before deciding: on a busy CI runner the server's JVM
    /// can take longer than one short request to answer, and a running server read as missing
    /// fails the test (GKM_REQUIRE_TEST_MAIL_SERVER=1). Gives up after about 20 seconds.
    private func isRunning() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(apiPort)/api/configuration")!)
        request.timeoutInterval = 5
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
        }
        return false
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

    /// Puts synthetic messages in the user's inbox, oldest first. `receivedDaysAgo` gives each
    /// message's received date at the provider (IMAP APPEND date-time); without it they are
    /// received now.
    func append(_ subjects: [String], for user: User, receivedDaysAgo: [Int]? = nil) async throws {
        let connections = AccountConnections(trust: trust)
        let settings = MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "localhost", port: imapsPort, security: .implicitTLS, username: user.address),
            smtp: MailServerSettings(host: "localhost", port: smtpsPort, security: .implicitTLS, username: user.address))
        try await connections.imap(settings, password: Secret(user.password)).withSession { session in
            for (index, subject) in subjects.enumerated() {
                let raw = "From: Bo <bo@example.net>\r\nTo: \(user.address)\r\nSubject: \(subject)\r\nMessage-ID: <\(UUID().uuidString)@example.net>\r\nDate: Tue, 24 Nov 2026 0\(index % 10):00:00 +0000\r\n\r\n\(subject) body.\r\n"
                let receivedAt = receivedDaysAgo.map { Date().addingTimeInterval(-Double($0[index]) * 86_400) }
                _ = try await session.append(Data(raw.utf8), to: "INBOX", flags: MessageFlags(), receivedAt: receivedAt)
            }
        }
    }
}

struct MissingLocalMailServer: Error, CustomStringConvertible {
    var description: String { "GKM_REQUIRE_TEST_MAIL_SERVER=1 but the local test mail server is not running" }
}
