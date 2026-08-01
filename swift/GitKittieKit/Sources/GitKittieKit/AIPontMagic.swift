import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AIPontProvider: String, CaseIterable, Sendable {
    case openAICompatible
    case anthropic
    case gemini

    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI compatible"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        }
    }
}

public struct AIPontMagicConfiguration: Sendable, Equatable {
    public let provider: AIPontProvider
    public let apiKey: String
    public let model: String
    public let endpoint: URL?

    public init(provider: AIPontProvider, apiKey: String, model: String, endpoint: URL? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }
}

public struct AIPontMagicRequest: Sendable, Equatable {
    public let subject: String
    public let body: String
    public let diff: String

    public init(subject: String, body: String, diff: String) {
        self.subject = subject
        self.body = body
        self.diff = diff
    }
}

public enum AIPontMagicError: LocalizedError, Sendable {
    case missingAPIKey
    case missingModel
    case invalidResponse
    case providerRejected(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your AI provider API key before using Magic."
        case .missingModel:
            return "Choose an AI model before using Magic."
        case .invalidResponse:
            return "The AI provider returned an invalid Magic response."
        case let .providerRejected(message):
            return "The AI provider rejected the Magic request: \(message)"
        }
    }
}

public protocol AIPontHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionAIPontTransport: AIPontHTTPTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIPontMagicError.invalidResponse }
        return (data, http)
    }
}

public struct AIPontMagicService: Sendable {
    private let transport: any AIPontHTTPTransport

    public init(transport: any AIPontHTTPTransport = URLSessionAIPontTransport()) {
        self.transport = transport
    }

    public func draftCommitMessage(
        configuration: AIPontMagicConfiguration,
        request magicRequest: AIPontMagicRequest
    ) async throws -> String {
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIPontMagicError.missingAPIKey }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIPontMagicError.missingModel }

        let request = try urlRequest(configuration: configuration, model: model, apiKey: key, magicRequest: magicRequest)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw AIPontMagicError.providerRejected(String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)")
        }
        return try parseDraft(data, provider: configuration.provider)
    }

    private func urlRequest(
        configuration: AIPontMagicConfiguration,
        model: String,
        apiKey: String,
        magicRequest: AIPontMagicRequest
    ) throws -> URLRequest {
        let endpoint = configuration.endpoint ?? defaultEndpoint(for: configuration.provider)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = Self.prompt(for: magicRequest)
        switch configuration.provider {
        case .openAICompatible:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try jsonData([
                "model": model,
                "messages": [
                    ["role": "system", "content": Self.systemPrompt],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.2
            ])
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try jsonData([
                "model": model,
                "max_tokens": 500,
                "temperature": 0.2,
                "system": Self.systemPrompt,
                "messages": [
                    ["role": "user", "content": prompt]
                ]
            ])
        case .gemini:
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            let existingItems = components?.queryItems ?? []
            components?.queryItems = existingItems + [URLQueryItem(name: "key", value: apiKey)]
            if let url = components?.url {
                request.url = url
            }
            request.httpBody = try jsonData([
                "contents": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": "\(Self.systemPrompt)\n\n\(prompt)"]
                        ]
                    ]
                ],
                "generationConfig": [
                    "temperature": 0.2
                ]
            ])
        }
        return request
    }

    private func parseDraft(_ data: Data, provider: AIPontProvider) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw AIPontMagicError.invalidResponse }
        let text: String?
        switch provider {
        case .openAICompatible:
            let choices = root["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            text = message?["content"] as? String
        case .anthropic:
            let content = root["content"] as? [[String: Any]]
            text = content?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .gemini:
            let candidates = root["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            text = parts?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw AIPontMagicError.invalidResponse }
        return trimmed
    }

    private func defaultEndpoint(for provider: AIPontProvider) -> URL {
        switch provider {
        case .openAICompatible:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic:
            return URL(string: "https://api.anthropic.com/v1/messages")!
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent")!
        }
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func prompt(for request: AIPontMagicRequest) -> String {
        """
        Existing subject:
        \(request.subject)

        Existing body:
        \(request.body.isEmpty ? "(empty)" : request.body)

        Diff:
        \(request.diff)
        """
    }

    private static let systemPrompt = """
    You write precise git commit messages. Return only the final commit message:
    one imperative subject line, then an optional blank line and body. Do not use markdown.
    """
}
