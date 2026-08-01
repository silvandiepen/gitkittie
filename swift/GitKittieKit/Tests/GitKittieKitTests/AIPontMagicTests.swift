import XCTest
@testable import GitKittieKit

final class AIPontMagicTests: XCTestCase {
    func testOpenAICompatibleMagicRequestParsesCommitMessage() async throws {
        let transport = MockAIPontTransport(body: #"{"choices":[{"message":{"content":"feat: explain history rewrite\n\nMake rebasing clearer."}}]}"#)
        let service = AIPontMagicService(transport: transport)

        let draft = try await service.draftCommitMessage(
            configuration: AIPontMagicConfiguration(
                provider: .openAICompatible,
                apiKey: "test-key",
                model: "gpt-test",
                endpoint: URL(string: "https://example.com/v1/chat/completions")
            ),
            request: AIPontMagicRequest(subject: "rough", body: "", diff: "+new line")
        )

        XCTAssertEqual(draft, "feat: explain history rewrite\n\nMake rebasing clearer.")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        let body = try XCTUnwrap(request.httpBody)
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("gpt-test"))
        XCTAssertTrue(text.contains("+new line"))
    }

    func testAnthropicMagicRequestParsesCommitMessage() async throws {
        let transport = MockAIPontTransport(body: #"{"content":[{"type":"text","text":"fix: resolve conflict wording"}]}"#)
        let service = AIPontMagicService(transport: transport)

        let draft = try await service.draftCommitMessage(
            configuration: AIPontMagicConfiguration(
                provider: .anthropic,
                apiKey: "anthropic-key",
                model: "claude-test",
                endpoint: URL(string: "https://example.com/v1/messages")
            ),
            request: AIPontMagicRequest(subject: "rough", body: "body", diff: "-old\n+new")
        )

        XCTAssertEqual(draft, "fix: resolve conflict wording")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testGeminiMagicRequestUsesQueryKeyAndParsesCommitMessage() async throws {
        let transport = MockAIPontTransport(body: #"{"candidates":[{"content":{"parts":[{"text":"refactor: split commit flow"}]}}]}"#)
        let service = AIPontMagicService(transport: transport)

        let draft = try await service.draftCommitMessage(
            configuration: AIPontMagicConfiguration(
                provider: .gemini,
                apiKey: "gemini-key",
                model: "ignored-by-gemini-endpoint",
                endpoint: URL(string: "https://example.com/generateContent")
            ),
            request: AIPontMagicRequest(subject: "rough", body: "", diff: "+hunk")
        )

        XCTAssertEqual(draft, "refactor: split commit flow")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url?.query, "key=gemini-key")
    }

    func testMagicRequiresBYOKKey() async {
        let service = AIPontMagicService(transport: MockAIPontTransport(body: "{}"))

        do {
            _ = try await service.draftCommitMessage(
                configuration: AIPontMagicConfiguration(provider: .openAICompatible, apiKey: " ", model: "gpt-test"),
                request: AIPontMagicRequest(subject: "rough", body: "", diff: "+line")
            )
            XCTFail("Expected missing API key")
        } catch AIPontMagicError.missingAPIKey {
        } catch {
            XCTFail("Expected missing API key, got \(error)")
        }
    }
}

private final class MockAIPontTransport: AIPontHTTPTransport, @unchecked Sendable {
    private let body: String
    private let statusCode: Int
    private(set) var lastRequest: URLRequest?

    init(body: String, statusCode: Int = 200) {
        self.body = body
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}
