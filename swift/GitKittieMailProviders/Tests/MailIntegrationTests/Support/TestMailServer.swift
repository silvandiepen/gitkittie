import Foundation
import MailProvider
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest

/// The local GreenMail started by `scripts/test-mail-server.sh start`. Tests skip, with a clear
/// message, when it is not running, so `swift test` stays green without it.
struct TestMailServer {
    static let skipMessage = "Local test mail server is not running. Start it with `scripts/test-mail-server.sh start` (in swift/GitKittieMailKit) to run the integration tests."

    let stateDirectory: URL
    let caPEM: Data
    let host = "localhost"
    let imapsPort = 3993
    let smtpsPort = 3465
    let smtpPlainPort = 3025
    let imapPlainPort = 3143
    let apiPort = 3080

    static func require() async throws -> TestMailServer {
        let environment = ProcessInfo.processInfo.environment
        // In the iOS Simulator the home directory is the test's own container; the server and its
        // state are on the Mac, whose home the simulator passes in. Loopback is the Mac's.
        let home = environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let state = environment["GKM_TEST_MAIL_SERVER_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/GitKittieMail/test-mail-server")
        guard let ca = try? Data(contentsOf: state.appendingPathComponent("tls/ca.pem")),
              await isListening(port: 3993), await isListening(port: 3080)
        else {
            // CI starts the server and sets this, so a broken server fails instead of skipping.
            if environment["GKM_REQUIRE_TEST_MAIL_SERVER"] == "1" {
                throw MissingServer()
            }
            throw XCTSkip(skipMessage)
        }
        return TestMailServer(stateDirectory: state, caPEM: ca)
    }

    static func isListening(port: Int) async -> Bool {
        do {
            let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(1))
                .connect(host: "127.0.0.1", port: port).get()
            try? await channel.close()
            return true
        } catch {
            return false
        }
    }

    var trust: TrustPolicy { .customRoots(pem: [caPEM]) }
    var imaps: ServerEndpoint { ServerEndpoint(host: host, port: imapsPort, security: .implicitTLS, trust: trust) }
    var smtps: ServerEndpoint { ServerEndpoint(host: host, port: smtpsPort, security: .implicitTLS, trust: trust) }
    var serverCertificatePEM: URL { stateDirectory.appendingPathComponent("tls/server.pem") }
    var serverKeyPEM: URL { stateDirectory.appendingPathComponent("tls/server.key") }

    /// A fresh synthetic account per test, so tests never see each other's mail.
    func makeUser(function: String = #function) async throws -> TestUser {
        let id = UUID().uuidString.prefix(8).lowercased()
        // XCTest names look like "-[Suite testName]".
        let testName = function.split(separator: " ").last.map(String.init) ?? "test"
        let name = String(testName.filter(\.isLetter).lowercased().prefix(24))
        let address = "\(name)-\(id)@example.com"
        let password = "pw-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(apiPort)/api/user")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": address, "login": address, "password": password])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("could not create a test user through the GreenMail API")
        }
        return TestUser(address: address, password: Secret(password), rawPassword: password)
    }
}

struct MissingServer: Error, CustomStringConvertible {
    var description: String { "GKM_REQUIRE_TEST_MAIL_SERVER=1 but " + TestMailServer.skipMessage }
}

struct TestUser {
    let address: String
    let password: Secret
    /// Kept only to search logs for leaks.
    let rawPassword: String

    var credential: MailCredential { .password(username: address, password: password) }
}

/// Collects every log record at trace level, so a test can prove the password never appears.
final class CapturedLog: Sendable {
    private let records = NIOLockedValueBox<[String]>([])

    var log: MailLog {
        MailLog(minimumLevel: .trace) { [records] record in
            records.withLockedValue { $0.append("[\(record.level)] \(record.category): \(record.message)") }
        }
    }

    var lines: [String] { records.withLockedValue { $0 } }

    /// Forgets what was logged so far, to look at one step on its own.
    func reset() { records.withLockedValue { $0.removeAll() } }

    func assertNoSecret(_ secret: String, file: StaticString = #filePath, line: UInt = #line) {
        let all = lines.joined(separator: "\n")
        XCTAssertFalse(lines.isEmpty, "nothing was logged", file: file, line: line)
        XCTAssertFalse(all.contains(secret), "password found in the log", file: file, line: line)
        XCTAssertFalse(all.contains(Data(secret.utf8).base64EncodedString()), "base64 password found in the log", file: file, line: line)
    }
}
