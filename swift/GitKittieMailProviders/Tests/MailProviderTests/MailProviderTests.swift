import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import MailProvider

final class SecretTests: XCTestCase {
    func testSecretNeverPrints() {
        let secret = Secret("hunter2-app-password")
        let credential = MailCredential.password(username: "me@example.com", password: secret)
        var dumped = ""
        dump(credential, to: &dumped)
        for text in ["\(secret)", String(describing: secret), String(reflecting: secret), "\(credential)",
                     String(reflecting: credential), dumped] {
            XCTAssertFalse(text.contains("hunter2"), text)
        }
        XCTAssertEqual(secret.withValue { $0 }, "hunter2-app-password")
    }

    func testLogScrubsSecretsAndTheirBase64() {
        let records = LockedRecords()
        let secret = Secret("s3cret-Pw")
        let log = MailLog(minimumLevel: .trace) { records.append($0.message) }.scrubbing([secret])
        log.info("t", "leaked s3cret-Pw here")
        log.debug("t", "AUTH PLAIN \(Data("s3cret-Pw".utf8).base64EncodedString())")
        log.trace("t", "harmless")
        XCTAssertEqual(records.all.count, 3)
        XCTAssertFalse(records.all.joined().contains("s3cret-Pw"))
        XCTAssertFalse(records.all.joined().contains(Data("s3cret-Pw".utf8).base64EncodedString()))
    }

    func testLogLevelFilters() {
        let records = LockedRecords()
        let log = MailLog(minimumLevel: .warning) { records.append($0.message) }
        log.info("t", "dropped")
        log.error("t", "kept")
        XCTAssertEqual(records.all, ["kept"])
    }
}

final class SubmissionPolicyTests: XCTestCase {
    func testUncertainAlwaysReconcilesNeverRetries() {
        XCTAssertEqual(SubmissionFollowUp.after(.uncertain(reason: "lost"), providerSavesSentCopy: false), .reconcile)
        XCTAssertEqual(SubmissionFollowUp.after(.uncertain(reason: "lost"), providerSavesSentCopy: true), .reconcile)
    }

    func testAcceptedAppendsSentCopyOnlyWhenTheProviderDoesNot() {
        XCTAssertEqual(SubmissionFollowUp.after(.accepted(serverReply: "250"), providerSavesSentCopy: false), .markSent(appendSentCopy: true))
        XCTAssertEqual(SubmissionFollowUp.after(.accepted(serverReply: "250"), providerSavesSentCopy: true), .markSent(appendSentCopy: false))
    }

    func testNotSentRetriesOnlyTemporaryFailures() {
        XCTAssertEqual(SubmissionFollowUp.after(.notSent(reason: "421", permanent: false), providerSavesSentCopy: false), .retryLater)
        XCTAssertEqual(SubmissionFollowUp.after(.notSent(reason: "550", permanent: true), providerSavesSentCopy: false), .failed)
    }
}

final class ReconnectPolicyTests: XCTestCase {
    func testBackoffGrowsAndCaps() {
        let policy = ReconnectPolicy(maxAttempts: 10, initialDelay: .seconds(1), maxDelay: .seconds(10), jitter: 0.5)
        XCTAssertEqual(policy.delay(beforeRetry: 1, random: 0), .seconds(1))
        XCTAssertEqual(policy.delay(beforeRetry: 2, random: 0), .seconds(2))
        XCTAssertEqual(policy.delay(beforeRetry: 3, random: 0), .seconds(4))
        XCTAssertEqual(policy.delay(beforeRetry: 9, random: 0), .seconds(10))
        XCTAssertEqual(policy.delay(beforeRetry: 2, random: 1), .seconds(1))
    }

    func testRetriesConnectionProblemsOnlyAndStops() async throws {
        let policy = ReconnectPolicy(maxAttempts: 3, initialDelay: .milliseconds(1), maxDelay: .milliseconds(2), jitter: 0)

        var failures: [MailProviderError] = [.connectionLost("x"), .timedOut("y")]
        var attempts = 0
        let value = try await policy.retrying {
            attempts += 1
            if !failures.isEmpty { throw failures.removeFirst() }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 3)

        attempts = 0
        do {
            _ = try await policy.retrying { () async throws -> Int in
                attempts += 1
                throw MailProviderError.authenticationFailed("no")
            }
            XCTFail("authentication failures must not be retried")
        } catch {
            XCTAssertEqual(error as? MailProviderError, .authenticationFailed("no"))
        }
        XCTAssertEqual(attempts, 1)

        attempts = 0
        do {
            _ = try await policy.retrying { () async throws -> Int in
                attempts += 1
                throw MailProviderError.connectionFailed("down")
            }
            XCTFail("must give up after maxAttempts")
        } catch {}
        XCTAssertEqual(attempts, 3)
    }
}

final class EndpointTests: XCTestCase {
    func testICloudSettingsAndLoopback() {
        XCTAssertEqual(ServerEndpoint.iCloudIMAP.port, 993)
        XCTAssertEqual(ServerEndpoint.iCloudIMAP.security, .implicitTLS)
        XCTAssertEqual(ServerEndpoint.iCloudSMTP.port, 587)
        XCTAssertEqual(ServerEndpoint.iCloudSMTP.security, .startTLS)
        XCTAssertTrue(ServerEndpoint(host: "LOCALHOST", port: 1, security: .plaintextLoopbackOnly).isLoopback)
        XCTAssertFalse(ServerEndpoint(host: "mail.example.com", port: 1, security: .plaintextLoopbackOnly).isLoopback)
    }
}

final class LockedRecords: Sendable {
    private let box = NIOLockedValueBox<[String]>([])
    func append(_ message: String) { box.withLockedValue { $0.append(message) } }
    var all: [String] { box.withLockedValue { $0 } }
}
