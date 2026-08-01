import Foundation
import GitKittieKit

public struct GitBudMagicSettings: Equatable {
    public var provider: AIPontProvider
    public var model: String
    public var endpoint: String
    public var apiKey: String

    public init(provider: AIPontProvider, model: String, endpoint: String, apiKey: String) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.apiKey = apiKey
    }
}

public struct GitBudSettingsStore {
    private let defaults: UserDefaults
    private let magicKeychain: KeychainService
    private let providerKeychain: KeychainService
    private let defaultProtectedBranchPatterns = GitProtectedBranchPolicy().patterns

    public init(
        defaults: UserDefaults = .standard,
        magicKeychain: KeychainService = KeychainService(service: "app.hakobs.gitbud", account: "magic-api-key"),
        providerKeychain: KeychainService = KeychainService(service: "app.hakobs.gitbud", account: "provider-access-token")
    ) {
        self.defaults = defaults
        self.magicKeychain = magicKeychain
        self.providerKeychain = providerKeychain
    }

    public func loadMagicSettings() -> GitBudMagicSettings {
        let providerRaw = defaults.string(forKey: Keys.magicProvider) ?? AIPontProvider.openAICompatible.rawValue
        let provider = AIPontProvider(rawValue: providerRaw) ?? .openAICompatible
        let model = defaults.string(forKey: Keys.magicModel) ?? "gpt-4o-mini"
        let endpoint = defaults.string(forKey: Keys.magicEndpoint) ?? "https://api.openai.com/v1/chat/completions"
        let apiKey = (try? magicKeychain.load()) ?? ""
        return GitBudMagicSettings(provider: provider, model: model, endpoint: endpoint, apiKey: apiKey)
    }

    public func saveMagicSettings(_ settings: GitBudMagicSettings) throws {
        defaults.set(settings.provider.rawValue, forKey: Keys.magicProvider)
        defaults.set(settings.model, forKey: Keys.magicModel)
        defaults.set(settings.endpoint, forKey: Keys.magicEndpoint)
        try magicKeychain.save(settings.apiKey)
    }

    public func loadProviderAccessToken() -> String {
        (try? providerKeychain.load()) ?? ""
    }

    public func saveProviderAccessToken(_ token: String) throws {
        try providerKeychain.save(token)
    }

    public func clearProviderAccessToken() throws {
        try providerKeychain.delete()
    }

    public func loadProtectedBranchPatterns() -> [String] {
        let patterns = defaults.stringArray(forKey: Keys.protectedBranchPatterns) ?? defaultProtectedBranchPatterns
        let cleaned = cleanProtectedBranchPatterns(patterns)
        return cleaned.isEmpty ? defaultProtectedBranchPatterns : cleaned
    }

    public func saveProtectedBranchPatterns(_ patterns: [String]) {
        defaults.set(cleanProtectedBranchPatterns(patterns), forKey: Keys.protectedBranchPatterns)
    }

    public func resetProtectedBranchPatterns() {
        defaults.removeObject(forKey: Keys.protectedBranchPatterns)
    }

    private func cleanProtectedBranchPatterns(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        return patterns.compactMap { pattern in
            let cleaned = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { return nil }
            seen.insert(cleaned)
            return cleaned
        }
    }

    private enum Keys {
        static let magicProvider = "magic.provider"
        static let magicModel = "magic.model"
        static let magicEndpoint = "magic.endpoint"
        static let protectedBranchPatterns = "protectedBranchPatterns"
    }
}
