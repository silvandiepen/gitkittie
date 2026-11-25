import Foundation
import MailCore

// Spaces in the store (GKM-022). Every change is one atomic write of one space's file in
// `Mail/spaces/`, then the index's copy of that space's members. Nothing here reaches a
// provider: spaces are GitKittie metadata (MAIL-042), and taking a message out of a space, or
// deleting a space, leaves the message where it was, on disk and at the provider.

/// How many stored messages a space holds.
public struct SpaceCount: Equatable, Sendable {
    public var messages: Int
    public var unread: Int
}

extension StoreLocations {
    var spacesFolder: URL { mailFolder.appendingPathComponent("spaces", isDirectory: true) }

    func spaceURL(_ id: MailSpaceID) -> URL { spacesFolder.appendingPathComponent("\(id.rawValue).json") }
}

extension MailStore {
    // MARK: Reading

    /// Every readable space, in sidebar order. A file that cannot be read (damaged, or not a
    /// space) is left alone and reported by `unreadableSpaceFiles()`, never deleted.
    public func spaces() throws -> [MailSpace] {
        try loadSpaces().spaces
    }

    /// The names of files in `Mail/spaces/` that are not readable spaces.
    public func unreadableSpaceFiles() throws -> [String] {
        try loadSpaces().unreadable
    }

    public func space(_ id: MailSpaceID) throws -> MailSpace {
        let url = locations.spaceURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MailStoreError.spaceNotFound(id.rawValue) }
        return try JSONCoding.decoder.decode(MailSpace.self, from: Data(contentsOf: url))
    }

    /// Stored messages per space (members whose message is no longer stored are not counted).
    public func spaceCounts() throws -> [MailSpaceID: SpaceCount] {
        try index.spaceCounts().mapValues { SpaceCount(messages: $0.messages, unread: $0.unread) }
    }

    /// The spaces a message is in.
    public func spaces(containing id: MailMessageID) throws -> Set<MailSpaceID> {
        try index.spaces(containing: id)
    }

    // MARK: Creating, changing, deleting

    /// A new, empty space at the end of the sidebar.
    @discardableResult
    public func createSpace(name: String, icon: String = SpaceAppearance.defaultIcon, color: String = SpaceAppearance.defaultColor,
                            now: Date = Date()) throws -> MailSpace {
        let order = (try spaces().map(\.order).max() ?? -1) + 1
        let space = MailSpace(name: try Self.validName(name), icon: icon, color: color, order: order, created: now)
        try write(space, now: now)
        return space
    }

    /// Renames a space and changes its look.
    @discardableResult
    public func updateSpace(_ id: MailSpaceID, name: String, icon: String, color: String, now: Date = Date()) throws -> MailSpace {
        var space = try editable(id)
        space.name = try Self.validName(name)
        space.icon = icon.isEmpty ? SpaceAppearance.defaultIcon : icon
        space.color = color.isEmpty ? SpaceAppearance.defaultColor : color
        try write(space, now: now)
        return space
    }

    /// Replaces a space's rules and adds what they match now. Returns how many messages were
    /// added. Messages earlier rules added stay: they are in the space, and the person takes
    /// them out by hand if they should go.
    @discardableResult
    public func setRules(_ rules: [SpaceRule], of id: MailSpaceID, now: Date = Date()) throws -> Int {
        var space = try editable(id)
        let normalized = rules.map(\.normalized)
        if normalized.contains(where: \.isEmpty) {
            throw MailStoreError.invalidSpace("A rule needs a sender, a domain, a list or words in the subject.")
        }
        space.rules = normalized
        let added = try addRuleMatches(to: &space, now: now)
        try write(space, now: now)
        return added
    }

    /// Deletes the space's file. Its messages, their files and the provider are not touched.
    public func deleteSpace(_ id: MailSpaceID) throws {
        let url = locations.spaceURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MailStoreError.spaceNotFound(id.rawValue) }
        try FileManager.default.removeItem(at: url)
        try index.setSpaceMembers(nil, of: id)
    }

    /// Puts spaces in this order; spaces not named keep their relative order after them.
    public func reorderSpaces(_ ids: [MailSpaceID], now: Date = Date()) throws {
        let current = try spaces()
        let named = ids.compactMap { id in current.first { $0.id == id } }
        let rest = current.filter { space in !ids.contains(space.id) }
        for (position, space) in (named + rest).enumerated() where space.order != position {
            var changed = space
            guard changed.format <= MailSpace.formatVersion else { continue }
            changed.order = position
            try write(changed, now: now)
        }
    }

    // MARK: Membership

    /// Adds messages by hand. A message taken out earlier comes back. Returns how many were new.
    @discardableResult
    public func addMessages(_ ids: [MailMessageID], to id: MailSpaceID, now: Date = Date()) throws -> Int {
        var space = try editable(id)
        let present = space.memberIDs
        let added = Self.whole(now)
        let fresh = try index.identities(of: ids.filter { !present.contains($0) }).map {
            SpaceMember(message: $0.id, account: $0.account, messageId: $0.messageID, emlSha256: $0.emlSha256, added: added,
                        source: SpaceMember.manual)
        }
        let excludedBefore = space.excluded.count
        let requested = Set(ids)
        space.excluded.removeAll { requested.contains($0.message) }
        guard !fresh.isEmpty || space.excluded.count != excludedBefore else { return 0 }
        space.members += Self.unique(fresh)
        try write(space, now: now)
        return fresh.count
    }

    /// Adds every message of these conversations.
    @discardableResult
    public func addThreads(_ threadIDs: [String], to id: MailSpaceID, now: Date = Date()) throws -> Int {
        try addMessages(threadIDs.flatMap { try index.ids(inThread: $0) }, to: id, now: now)
    }

    /// Takes messages out by hand, and remembers that so a rule does not add them back. The
    /// messages themselves are not touched. Returns how many were in the space.
    @discardableResult
    public func removeMessages(_ ids: [MailMessageID], from id: MailSpaceID, now: Date = Date()) throws -> Int {
        var space = try editable(id)
        let remove = Set(ids)
        let leaving = space.members.filter { remove.contains($0.message) }
        guard !leaving.isEmpty else { return 0 }
        space.members.removeAll { remove.contains($0.message) }
        let removed = Self.whole(now)
        let excludedAlready = space.excludedIDs
        space.excluded += leaving.filter { !excludedAlready.contains($0.message) }.map {
            var member = $0
            member.added = removed
            member.source = SpaceMember.manual
            return member
        }
        try write(space, now: now)
        return leaving.count
    }

    /// Takes every message of these conversations out.
    @discardableResult
    public func removeThreads(_ threadIDs: [String], from id: MailSpaceID, now: Date = Date()) throws -> Int {
        try removeMessages(threadIDs.flatMap { try index.ids(inThread: $0) }, from: id, now: now)
    }

    // MARK: Rules

    /// What a rule would add to a space (or to a new space, with `space` nil), without saving.
    public func previewRule(_ rule: SpaceRule, for space: MailSpaceID? = nil, samples: Int = 5) throws -> SpaceRulePreview {
        let matches = try index.ids(matching: rule)
        var skip = Set<MailMessageID>()
        if let space, let existing = try? self.space(space) { skip = existing.memberIDs.union(existing.excludedIDs) }
        return SpaceRulePreview(matchCount: matches.count, newCount: matches.filter { !skip.contains($0) }.count,
                                samples: try index.summaries(matching: rule, limit: samples))
    }

    /// Runs every space's rules over the stored mail and adds what they match (new mail after a
    /// sync or an import). Only spaces that gain messages are written. Returns how many were added.
    @discardableResult
    public func applySpaceRules(now: Date = Date()) throws -> Int {
        var total = 0
        for var space in try spaces() where !space.rules.isEmpty && space.format <= MailSpace.formatVersion {
            let added = try addRuleMatches(to: &space, now: now)
            if added > 0 {
                try write(space, now: now)
                total += added
            }
        }
        return total
    }

    // MARK: The index's copy

    /// Copies every space's membership into the index: on open, after a rebuild, and when the
    /// folder may have changed underneath (another device through a synced folder).
    public func refreshSpaceIndex() throws {
        var members: [MailSpaceID: Set<MailMessageID>] = [:]
        for space in try spaces() { members[space.id] = space.memberIDs }
        try index.replaceSpaceMembers(members)
    }

    // MARK: Helpers

    private func loadSpaces() throws -> (spaces: [MailSpace], unreadable: [String]) {
        let folder = locations.spacesFolder
        guard FileManager.default.fileExists(atPath: folder.path) else { return ([], []) }
        var spaces: [MailSpace] = []
        var unreadable: [String] = []
        for file in try sortedContents(of: folder) where !file.lastPathComponent.hasPrefix(".") {
            guard file.pathExtension == "json", let id = MailSpaceID(file.deletingPathExtension().lastPathComponent),
                  let space = try? JSONCoding.decoder.decode(MailSpace.self, from: Data(contentsOf: file)), space.id == id else {
                unreadable.append(file.lastPathComponent)
                continue
            }
            spaces.append(space)
        }
        spaces.sort { ($0.order, $0.name.lowercased(), $0.id) < ($1.order, $1.name.lowercased(), $1.id) }
        return (spaces, unreadable)
    }

    private func editable(_ id: MailSpaceID) throws -> MailSpace {
        let space = try space(id)
        guard space.format <= MailSpace.formatVersion else { throw MailStoreError.unsupportedSpaceFormat(space.format) }
        return space
    }

    func write(_ space: MailSpace, now: Date) throws {
        var space = space
        space.format = MailSpace.formatVersion
        space.modified = Self.whole(now)
        try writer.write(JSONCoding.prettyEncoder.encode(space), to: locations.spaceURL(space.id))
        try index.setSpaceMembers(space.memberIDs, of: space.id)
    }

    /// Adds what the space's rules match and it does not hold or exclude. Returns the count.
    private func addRuleMatches(to space: inout MailSpace, now: Date) throws -> Int {
        var skip = space.memberIDs.union(space.excludedIDs)
        var fresh: [SpaceMember] = []
        let added = Self.whole(now)
        for rule in space.rules {
            let ids = try index.ids(matching: rule).filter { !skip.contains($0) }
            for identity in try index.identities(of: ids) {
                fresh.append(SpaceMember(message: identity.id, account: identity.account, messageId: identity.messageID,
                                         emlSha256: identity.emlSha256, added: added, source: SpaceMember.rule(rule.id)))
                skip.insert(identity.id)
            }
        }
        space.members += fresh
        return fresh.count
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MailStoreError.invalidSpace("A space needs a name.") }
        return String(trimmed.prefix(200))
    }

    private static func unique(_ members: [SpaceMember]) -> [SpaceMember] {
        var seen = Set<MailMessageID>()
        return members.filter { seen.insert($0.message).inserted }
    }

    /// Whole seconds: dates are stored as ISO 8601 and must read back equal.
    static func whole(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
}
