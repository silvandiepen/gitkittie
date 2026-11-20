import Foundation
import GitKittieKit

/// A config inferred from a board's folders + card fields, used to prefill the setup sheet.
public struct DetectedBoardConfig {
    public var lanes: [Lane] = []
    public var priorities: [Priority] = []
    public var users: [User] = []
    public var types: [String] = []
    public var epics: [Epic] = []

    public init(lanes: [Lane] = [], priorities: [Priority] = [], users: [User] = [],
                types: [String] = [], epics: [Epic] = []) {
        self.lanes = lanes; self.priorities = priorities; self.users = users
        self.types = types; self.epics = epics
    }
}

/// A board the user selected within a repo — a project folder path, its display name,
/// and a small summary shown in the boards list.
public struct SelectedBoard: Codable, Identifiable, Hashable {
    public var folder: String   // project folder path relative to the repo root ("" = repo root board)
    public var name: String
    public var laneCount: Int = 0
    public var memberCount: Int = 0
    public var hasBacklog: Bool = false
    /// The board's `icon:` and `color:` as last read from its README, so the sidebar can
    /// show them without opening the board.
    public var icon: String?
    public var color: String?
    public var id: String { folder }

    public init(folder: String, name: String, laneCount: Int = 0, memberCount: Int = 0, hasBacklog: Bool = false) {
        self.folder = folder; self.name = name; self.laneCount = laneCount
        self.memberCount = memberCount; self.hasBacklog = hasBacklog
    }

    public var subtitle: String {
        var parts = ["\(laneCount) lane\(laneCount == 1 ? "" : "s")"]
        if hasBacklog { parts.append("backlog") }
        if memberCount > 0 { parts.append("\(memberCount) member\(memberCount == 1 ? "" : "s")") }
        if !folder.isEmpty { parts.append(folder) }
        return parts.joined(separator: " · ")
    }
}

/// Where an added entry's files come from.
public enum RepoSourceKind: Codable, Hashable, Sendable {
    /// A repo on the connected git provider (GitHub/GitLab), over its API.
    case provider
    /// A folder on this device. No git: the folder's own sync tool (if any) commits.
    case localFolder(path: String, bookmark: Data?)
    /// A folder served by a GitKanban folder server (`apps/gitkanban-server`), e.g. over Tailscale.
    case folderServer(url: String)

    public var isFolder: Bool { self != .provider }
}

/// A repository (or folder) the user added, plus the boards (projects) they selected from
/// within it. Persisted so the home reopens instantly without re-scanning.
public struct AddedRepo: Codable, Identifiable, Hashable {
    public var namespace: String
    public var name: String
    public var branch: String
    public var isPrivate: Bool
    public var boards: [SelectedBoard] = []
    public var kind: RepoSourceKind = .provider

    public var fullName: String {
        switch kind {
        case .provider: return "\(namespace)/\(name)"
        case .localFolder(let path, _): return path
        case .folderServer(let url): return url
        }
    }
    public var id: String { fullName }

    /// The short label shown in lists.
    public var displayName: String {
        switch kind {
        case .provider: return fullName
        case .localFolder, .folderServer: return name
        }
    }

    /// SF Symbol for the entry.
    public var symbolName: String {
        switch kind {
        case .provider: return isPrivate ? "lock.fill" : "book.closed"
        case .localFolder: return "folder"
        case .folderServer: return "server.rack"
        }
    }

    public init(namespace: String, name: String, branch: String, isPrivate: Bool,
                boards: [SelectedBoard] = [], kind: RepoSourceKind = .provider) {
        self.namespace = namespace; self.name = name; self.branch = branch
        self.isPrivate = isPrivate; self.boards = boards; self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case namespace, name, branch, isPrivate, boards, kind }

    /// Entries saved before folder sources existed have no `kind`: they are provider repos.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try c.decode(String.self, forKey: .namespace)
        name = try c.decode(String.self, forKey: .name)
        branch = try c.decode(String.self, forKey: .branch)
        isPrivate = try c.decode(Bool.self, forKey: .isPrivate)
        boards = try c.decodeIfPresent([SelectedBoard].self, forKey: .boards) ?? []
        kind = try c.decodeIfPresent(RepoSourceKind.self, forKey: .kind) ?? .provider
    }
}
