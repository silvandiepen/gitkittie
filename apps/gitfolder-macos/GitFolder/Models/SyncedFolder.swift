import Foundation

struct SyncedFolder: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var localPath: String
    var bookmarkData: Data?
    var repoUrl: String
    var provider: String
    var authMode: String
    var branch: String
    var syncIntervalMinutes: Int
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastSyncAt: Date?
    var lastSuccessfulSyncAt: Date?
    var lastCheckedAt: Date?
    var lastStatus: SyncStatus
    var lastError: UserFacingError?
    var storage: BucketStorageSettings? = nil

    var authModeValue: AuthMode {
        AuthMode(rawValue: authMode) ?? .ssh
    }

    var repositoryWebURLString: String {
        Self.webURLString(fromRepositoryURL: repoUrl)
    }

    static func webURLString(fromRepositoryURL rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let normalized = stripGitSuffixAndTrailingSlashes(from: trimmed)

        if let scpLikeURL = parseScpLikeGitURL(normalized) {
            return scpLikeURL
        }

        if var components = URLComponents(string: normalized), let scheme = components.scheme?.lowercased(), let host = components.host {
            if scheme == "ssh" {
                let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !path.isEmpty else { return normalized }
                return "https://\(host)/\(path)"
            }

            if scheme == "http" || scheme == "https" {
                components.scheme = "https"
                components.user = nil
                components.password = nil
                components.query = nil
                components.fragment = nil
                return stripGitSuffixAndTrailingSlashes(from: components.string ?? normalized)
            }
        }

        return normalized
    }

    private static func parseScpLikeGitURL(_ value: String) -> String? {
        guard let atIndex = value.firstIndex(of: "@"),
              let colonIndex = value[atIndex...].firstIndex(of: ":") else {
            return nil
        }

        let hostStart = value.index(after: atIndex)
        let pathStart = value.index(after: colonIndex)
        let host = String(value[hostStart..<colonIndex])
        let path = String(value[pathStart...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !host.isEmpty, !path.isEmpty else { return nil }
        return "https://\(host)/\(path)"
    }

    private static func stripGitSuffixAndTrailingSlashes(from value: String) -> String {
        var result = value
        while result.hasSuffix("/") {
            result.removeLast()
        }
        if result.hasSuffix(".git") {
            result.removeLast(4)
        }
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    static func create(
        name: String,
        localPath: String,
        bookmarkData: Data?,
        repoUrl: String,
        authMode: AuthMode = .githubToken,
        branch: String = "main",
        syncIntervalMinutes: Int = 15
    ) -> SyncedFolder {
        let now = Date()
        return SyncedFolder(
            id: UUID(),
            name: name,
            localPath: localPath,
            bookmarkData: bookmarkData,
            repoUrl: repoUrl,
            provider: "github",
            authMode: authMode.rawValue,
            branch: branch,
            syncIntervalMinutes: syncIntervalMinutes,
            enabled: true,
            createdAt: now,
            updatedAt: now,
            lastSyncAt: nil,
            lastSuccessfulSyncAt: nil,
            lastCheckedAt: nil,
            lastStatus: .idle,
            lastError: nil,
            storage: nil
        )
    }
}

struct BucketStorageSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var endpoint: String
    var bucket: String
    var region: String
    var publicBaseURL: String
    var minimumFileSizeMB: Int
    var offloadExtensions: [String]
    var keepDownloadedPatterns: [String]

    init(
        enabled: Bool,
        endpoint: String,
        bucket: String,
        region: String = "auto",
        publicBaseURL: String,
        minimumFileSizeMB: Int,
        offloadExtensions: [String],
        keepDownloadedPatterns: [String]
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.publicBaseURL = publicBaseURL
        self.minimumFileSizeMB = minimumFileSizeMB
        self.offloadExtensions = offloadExtensions
        self.keepDownloadedPatterns = keepDownloadedPatterns
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, endpoint, bucket, region, publicBaseURL, minimumFileSizeMB, offloadExtensions, keepDownloadedPatterns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        bucket = try container.decode(String.self, forKey: .bucket)
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? "auto"
        publicBaseURL = try container.decode(String.self, forKey: .publicBaseURL)
        minimumFileSizeMB = try container.decode(Int.self, forKey: .minimumFileSizeMB)
        offloadExtensions = try container.decode([String].self, forKey: .offloadExtensions)
        keepDownloadedPatterns = try container.decode([String].self, forKey: .keepDownloadedPatterns)
    }

    static let defaults = BucketStorageSettings(
        enabled: false,
        endpoint: "https://8cef251b5fdcf6c6f63db98b7aa49f9a.r2.cloudflarestorage.com",
        bucket: "project-assets",
        region: "auto",
        publicBaseURL: "https://project-data.hakobs.com",
        minimumFileSizeMB: 25,
        offloadExtensions: ["psd", "psb", "mov", "mp4", "blend", "c4d", "zip"],
        keepDownloadedPatterns: ["**/*.md", "Tasks/**"]
    )
}

enum AuthMode: String, Codable, CaseIterable, Equatable, Sendable {
    case githubToken = "github_token"
    case ssh

    var label: String {
        switch self {
        case .githubToken: "GitHub Token"
        case .ssh: "SSH"
        }
    }
}

enum SyncStatus: String, Codable, Equatable, Sendable {
    case idle
    case checking
    case syncing
    case synced
    case paused
    case waitingForConnection = "waiting_for_connection"
    case needsAttention = "needs_attention"
    case error
    case conflict
}

struct UserFacingError: Codable, Equatable, Sendable {
    var code: String
    var title: String
    var message: String
    var recoverySuggestion: String?
    var technicalDetailsLogId: String?
    var affectedPaths: [String]? = nil
}
