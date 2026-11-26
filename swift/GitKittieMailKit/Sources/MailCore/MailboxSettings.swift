import Foundation

/// An account's choices about its folders at the provider (GKM-066, MAIL-093, MAIL-094): which
/// ones sync, which the sidebar shows and in what order, and which folder is Sent, Drafts,
/// Archive, Trash and Junk when the provider's own marking (IMAP SPECIAL-USE, or a well-known
/// name) is wrong or missing.
///
/// Folders are named by the provider's own id (IMAP: the mailbox name as sent on the wire),
/// never by their readable path. Kept in the account's `account.json`, so every device that
/// opens the mail folder shares them. Every list is optional on disk: a file from before these
/// settings, or one written by an older app, reads as "everything syncs and shows, as detected".
public struct MailboxSettings: Hashable, Codable, Sendable {
    /// Folders that do not sync: nothing new is downloaded from them and their flags are not
    /// checked. Mail already downloaded from them stays. The inbox always syncs.
    public var notSynced: [String]
    /// Folders the sidebar leaves out. They still sync unless also in ``notSynced``.
    public var hidden: [String]
    /// The sidebar's order; folders not in it follow, in the provider's order.
    public var order: [String]
    /// Special folders chosen by hand, by role (`sent`, `drafts`, `archive`, `trash`, `junk`):
    /// the folder that has the role instead of the one the provider marked.
    public var specialFolders: [String: String]

    public init(notSynced: [String] = [], hidden: [String] = [], order: [String] = [], specialFolders: [String: String] = [:]) {
        self.notSynced = notSynced
        self.hidden = hidden
        self.order = order
        self.specialFolders = specialFolders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notSynced = try container.decodeIfPresent([String].self, forKey: .notSynced) ?? []
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        specialFolders = try container.decodeIfPresent([String: String].self, forKey: .specialFolders) ?? [:]
    }

    /// The roles a folder can be chosen for, in the order settings list them.
    public static let choosableRoles = ["sent", "drafts", "archive", "trash", "junk"]
    /// Roles that are never moved by hand, and folders that have them are never chosen for
    /// another role: the inbox, and Gmail's All Mail and Starred, where a move out deletes or
    /// unstars instead of moving (MAIL-036).
    public static let fixedRoles: Set<String> = ["inbox", "all", "flagged"]

    public var isEmpty: Bool { self == MailboxSettings() }

    // MARK: Reading

    /// True when the folder syncs. The inbox always does.
    public func syncs(_ folder: String, detectedRole: String?) -> Bool {
        detectedRole == "inbox" || !notSynced.contains(folder)
    }

    /// True when the sidebar lists the folder.
    public func shows(_ folder: String) -> Bool { !hidden.contains(folder) }

    /// What each folder is for, once the choices made by hand are applied to what the provider
    /// detected (`detected`: every folder with its detected role, in the provider's order).
    ///
    /// A folder chosen for a role takes it, and the folder the provider marked for that role
    /// loses it, so each role has at most one folder. A choice is ignored when its folder is not
    /// in the list (deleted at the provider) or has a fixed role (``fixedRoles``), and a folder
    /// takes only the first role it is chosen for, in ``choosableRoles`` order.
    public func effectiveRoles(detected: [(name: String, role: String?)]) -> [String: String?] {
        var roles: [String: String?] = [:]
        for folder in detected { roles[folder.name] = .some(folder.role) }
        let detectedByName = Dictionary(detected.map { ($0.name, $0.role) }, uniquingKeysWith: { first, _ in first })
        var chosen: Set<String> = []
        for role in Self.choosableRoles {
            guard let folder = specialFolders[role], let detectedRole = detectedByName[folder], !chosen.contains(folder) else { continue }
            if let detectedRole, Self.fixedRoles.contains(detectedRole) { continue }
            for (name, current) in roles where current == role && name != folder { roles[name] = .some(nil) }
            roles[folder] = .some(role)
            chosen.insert(folder)
        }
        return roles
    }

    /// The folders in the sidebar's order: those in ``order`` first, as listed there, then the
    /// rest in the order given.
    public func ordered<Folder>(_ folders: [Folder], name: (Folder) -> String) -> [Folder] {
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return folders.enumerated()
            .sorted { lhs, rhs in
                let left = rank[name(lhs.element)] ?? Int.max
                let right = rank[name(rhs.element)] ?? Int.max
                return (left, lhs.offset) < (right, rhs.offset)
            }
            .map(\.element)
    }

    // MARK: Changing

    public mutating func setSyncs(_ syncs: Bool, folder: String) {
        notSynced.removeAll { $0 == folder }
        if !syncs { notSynced.append(folder); notSynced.sort() }
    }

    public mutating func setShows(_ shows: Bool, folder: String) {
        hidden.removeAll { $0 == folder }
        if !shows { hidden.append(folder); hidden.sort() }
    }

    /// Chooses the folder for a role, or goes back to the provider's (`nil`).
    public mutating func setSpecialFolder(_ folder: String?, for role: String) {
        precondition(Self.choosableRoles.contains(role), "not a role that can be chosen: \(role)")
        if let folder {
            // One role per folder: choosing it for this role takes it from any other.
            for (other, name) in specialFolders where name == folder && other != role { specialFolders[other] = nil }
            specialFolders[role] = folder
        } else {
            specialFolders[role] = nil
        }
    }

    /// Follows a folder renamed at the provider, and the folders inside it (whose ids start
    /// with the old id and the hierarchy `delimiter`).
    public mutating func renameFolder(_ old: String, to new: String, delimiter: Character?) {
        func renamed(_ name: String) -> String {
            if name == old { return new }
            if let delimiter, name.hasPrefix(old + String(delimiter)) { return new + name.dropFirst(old.count) }
            return name
        }
        notSynced = notSynced.map(renamed).sorted()
        hidden = hidden.map(renamed).sorted()
        order = order.map(renamed)
        specialFolders = specialFolders.mapValues(renamed)
    }

    /// Forgets a folder deleted at the provider, and the folders inside it.
    public mutating func removeFolder(_ folder: String, delimiter: Character?) {
        func gone(_ name: String) -> Bool {
            name == folder || delimiter.map { name.hasPrefix(folder + String($0)) } == true
        }
        notSynced.removeAll(where: gone)
        hidden.removeAll(where: gone)
        order.removeAll(where: gone)
        specialFolders = specialFolders.filter { !gone($0.value) }
    }
}
