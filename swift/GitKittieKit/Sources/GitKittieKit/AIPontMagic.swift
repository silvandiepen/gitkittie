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
        case .openAICompatible: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        }
    }

    /// Recommended models for this provider.
    public var recommendedModels: [String] {
        switch self {
        case .openAICompatible:
            return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo"]
        case .anthropic:
            return ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
        case .gemini:
            return ["gemini-1.5-pro", "gemini-1.5-flash", "gemini-1.0-pro"]
        }
    }

    /// Default model for this provider.
    public var defaultModel: String {
        recommendedModels.first ?? ""
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

// MARK: - AI Ticket Creation

/// A generated ticket from AI analysis of natural language input.
public struct AIGeneratedTicket: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public var title: String
    public var description: String
    public var priority: String?
    public var type: String?
    public var lane: String?
    public var epic: String?

    public init(title: String, description: String, priority: String? = nil, type: String? = nil, lane: String? = nil, epic: String? = nil) {
        self.title = title
        self.description = description
        self.priority = priority
        self.type = type
        self.lane = lane
        self.epic = epic
    }
}

/// A sample ticket for AI context.
public struct AITicketSample: Sendable {
    public let title: String
    public let description: String
    public let priority: String?
    public let type: String?

    public init(title: String, description: String, priority: String? = nil, type: String? = nil) {
        self.title = title
        self.description = description
        self.priority = priority
        self.type = type
    }
}

/// Context about the board to help AI generate appropriate tickets.
public struct AITicketContext: Sendable {
    public let projectName: String
    public let lanes: [String]
    public let priorities: [String]
    public let types: [String]
    public let epics: [String]
    public let existingTicketTitles: [String]
    public let sampleTickets: [AITicketSample]

    public init(projectName: String, lanes: [String], priorities: [String], types: [String], epics: [String], existingTicketTitles: [String], sampleTickets: [AITicketSample] = []) {
        self.projectName = projectName
        self.lanes = lanes
        self.priorities = priorities
        self.types = types
        self.epics = epics
        self.existingTicketTitles = existingTicketTitles
        self.sampleTickets = sampleTickets
    }
}

/// Service for AI-powered ticket creation from natural language.
public struct AITicketService: Sendable {
    private let transport: any AIPontHTTPTransport

    public init(transport: any AIPontHTTPTransport = URLSessionAIPontTransport()) {
        self.transport = transport
    }

    /// Generate tickets from natural language input, using board context to inform field values.
    public func generateTickets(
        configuration: AIPontMagicConfiguration,
        input: String,
        context: AITicketContext
    ) async throws -> [AIGeneratedTicket] {
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIPontMagicError.missingAPIKey }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIPontMagicError.missingModel }

        let request = try urlRequest(configuration: configuration, model: model, apiKey: key, input: input, context: context)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw AIPontMagicError.providerRejected(String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)")
        }
        return try parseTickets(data, provider: configuration.provider)
    }

    private func urlRequest(
        configuration: AIPontMagicConfiguration,
        model: String,
        apiKey: String,
        input: String,
        context: AITicketContext
    ) throws -> URLRequest {
        let endpoint = configuration.endpoint ?? defaultEndpoint(for: configuration.provider)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = Self.prompt(input: input, context: context)
        let system = Self.systemPrompt(context: context)

        switch configuration.provider {
        case .openAICompatible:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try jsonData([
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.3
            ])
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try jsonData([
                "model": model,
                "max_tokens": 2000,
                "temperature": 0.3,
                "system": system,
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
                            ["text": "\(system)\n\n\(prompt)"]
                        ]
                    ]
                ],
                "generationConfig": [
                    "temperature": 0.3
                ]
            ])
        }
        return request
    }

    private func parseTickets(_ data: Data, provider: AIPontProvider) throws -> [AIGeneratedTicket] {
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

        guard let responseText = text?.trimmingCharacters(in: .whitespacesAndNewlines), !responseText.isEmpty else {
            throw AIPontMagicError.invalidResponse
        }

        return parseTicketsFromResponse(responseText)
    }

    private func parseTicketsFromResponse(_ text: String) -> [AIGeneratedTicket] {
        // Try to parse JSON array first
        if let jsonData = text.data(using: .utf8),
           let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            return jsonArray.compactMap { dict in
                guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
                return AIGeneratedTicket(
                    title: title,
                    description: dict["description"] as? String ?? "",
                    priority: dict["priority"] as? String,
                    type: dict["type"] as? String,
                    lane: dict["lane"] as? String,
                    epic: dict["epic"] as? String
                )
            }
        }

        // Try to extract JSON from markdown code block
        let jsonPattern = "```(?:json)?\\s*\\n?(\\[.*?\\])\\s*```"
        if let regex = try? NSRegularExpression(pattern: jsonPattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let jsonRange = Range(match.range(at: 1), in: text),
           let jsonData = String(text[jsonRange]).data(using: .utf8),
           let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            return jsonArray.compactMap { dict in
                guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
                return AIGeneratedTicket(
                    title: title,
                    description: dict["description"] as? String ?? "",
                    priority: dict["priority"] as? String,
                    type: dict["type"] as? String,
                    lane: dict["lane"] as? String,
                    epic: dict["epic"] as? String
                )
            }
        }

        // Fallback: create a single ticket from the input if parsing fails
        return []
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

    static func prompt(input: String, context: AITicketContext) -> String {
        """
        Create ticket(s) from this input:
        \(input)

        Existing tickets in this board (for context, avoid duplicates):
        \(context.existingTicketTitles.prefix(15).joined(separator: "\n"))
        """
    }

    static func systemPrompt(context: AITicketContext) -> String {
        var prompt = """
        You are a ticket creation assistant for a kanban board called "\(context.projectName)".

        Available lanes: \(context.lanes.isEmpty ? "To do, In Progress, Done" : context.lanes.joined(separator: ", "))
        Available priorities: \(context.priorities.isEmpty ? "P0, P1, P2, P3" : context.priorities.joined(separator: ", "))
        Available types: \(context.types.isEmpty ? "feature, bug, chore" : context.types.joined(separator: ", "))
        \(context.epics.isEmpty ? "" : "Available epics: \(context.epics.joined(separator: ", "))")

        """

        // Add sample tickets to show the style
        if !context.sampleTickets.isEmpty {
            prompt += "\nHere are some example tickets from this board to show the style:\n"
            for sample in context.sampleTickets.prefix(3) {
                prompt += "- \(sample.title)"
                if let priority = sample.priority { prompt += " [\(priority)]" }
                if let type = sample.type { prompt += " (\(type))" }
                prompt += "\n  \(sample.description.prefix(150))\n"
            }
        }

        prompt += """

        GitKanban cards are stored as markdown files with YAML frontmatter:
        ```
        ---
        title: Clear, imperative title
        priority: P0
        type: feature
        ---

        Description of what needs to be done.

        - Acceptance criteria as bullet points
        - More details here
        ```

        Rules:
        1. Parse the user's natural language input and create one or more tickets
        2. If the input describes multiple distinct items, create separate tickets for each
        3. Write clear, actionable ticket titles (imperative mood, concise) - match the style of existing tickets
        4. Write helpful descriptions that add context - use markdown formatting
        5. Assign appropriate priority, type, and lane based on the content
        6. Default to the first lane (usually "To do") unless the input suggests otherwise
        7. Only use values from the available options above

        Return a JSON array of tickets. Each ticket object has these fields:
        - title (required): Clear, actionable title
        - description (required): Markdown description with context or acceptance criteria
        - priority (optional): One of the available priorities
        - type (optional): One of the available types
        - lane (optional): One of the available lanes
        - epic (optional): One of the available epics, if relevant

        Return ONLY the JSON array, no markdown code fences, no explanation.
        """

        return prompt
    }
}
