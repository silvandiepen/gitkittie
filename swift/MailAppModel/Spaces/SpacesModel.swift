import Foundation
import MailCore
import MailStore
import Observation

/// Spaces as the sidebar and the space view use them (GKM-022). UI-free: it turns what the
/// store's `Mail/spaces/` files hold into what the window shows, and sends every change back
/// to the store. Nothing here talks to a provider: spaces are GitKittie metadata (MAIL-042).
@MainActor
@Observable
final class SpacesModel {
    private(set) var spaces: [MailSpace] = []
    private(set) var counts: [MailSpaceID: SpaceCount] = [:]
    /// Files in `Mail/spaces/` that are not readable spaces: named in a notice, never deleted.
    private(set) var unreadableFiles: [String] = []
    /// An error from the last change, shown once.
    var actionError: String?

    private var store: MailStore?

    func attach(_ store: MailStore) {
        self.store = store
        spaces = []
        counts = [:]
    }

    func space(_ id: MailSpaceID) -> MailSpace? { spaces.first { $0.id == id } }

    // MARK: Loading

    /// Re-reads the spaces from the folder (another device may have changed them through a
    /// synced folder), optionally runs their rules over the stored mail, and refreshes counts.
    /// Returns how many messages the rules added.
    @discardableResult
    func refresh(applyRules: Bool = false) async -> Int {
        guard let store else { return 0 }
        var added = 0
        do {
            try await store.refreshSpaceIndex()
            // Applying rules writes the spaces' files: not while the folder is read-only (GKM-104).
            if applyRules, !store.isReadOnly { added = try await store.applySpaceRules() }
            spaces = try await store.spaces()
            unreadableFiles = try await store.unreadableSpaceFiles()
            counts = try await store.spaceCounts()
        } catch {
            actionError = String(describing: error)
        }
        return added
    }

    // MARK: Intents

    @discardableResult
    func create(name: String, icon: String, color: String, rules: [SpaceRule] = []) async -> MailSpace? {
        guard let store else { return nil }
        do {
            let space = try await store.createSpace(name: name, icon: icon, color: color)
            if !rules.isEmpty { try await store.setRules(rules, of: space.id) }
            await refresh()
            return self.space(space.id)
        } catch {
            actionError = String(describing: error)
            return nil
        }
    }

    /// Saves the editor: name, look and rules. Returns false (with `actionError`) when refused.
    @discardableResult
    func update(_ id: MailSpaceID, name: String, icon: String, color: String, rules: [SpaceRule]) async -> Bool {
        guard let store else { return false }
        do {
            try await store.updateSpace(id, name: name, icon: icon, color: color)
            if rules != space(id)?.rules { try await store.setRules(rules, of: id) }
            await refresh()
            return true
        } catch {
            actionError = String(describing: error)
            await refresh()
            return false
        }
    }

    /// Deletes the space. Its messages stay in the folder and at the provider.
    func delete(_ id: MailSpaceID) async {
        guard let store else { return }
        do { try await store.deleteSpace(id) } catch { actionError = String(describing: error) }
        await refresh()
    }

    /// Moves spaces as the sidebar's drag does (`List.onMove`).
    func move(from offsets: IndexSet, to destination: Int) async {
        guard let store else { return }
        var ids = spaces.map(\.id)
        let moving = offsets.sorted().map { ids[$0] }
        let insertAt = destination - offsets.filter { $0 < destination }.count
        ids.removeAll { moving.contains($0) }
        ids.insert(contentsOf: moving, at: min(max(insertAt, 0), ids.count))
        do { try await store.reorderSpaces(ids) } catch { actionError = String(describing: error) }
        await refresh()
    }

    /// Adds whole conversations by hand. Returns how many messages were new to the space.
    @discardableResult
    func add(threads threadIDs: [String], to id: MailSpaceID) async -> Int {
        guard let store, !threadIDs.isEmpty else { return 0 }
        do {
            let added = try await store.addThreads(threadIDs, to: id)
            await refresh()
            return added
        } catch {
            actionError = String(describing: error)
            return 0
        }
    }

    /// Takes whole conversations out; a rule will not add them back.
    @discardableResult
    func remove(threads threadIDs: [String], from id: MailSpaceID) async -> Int {
        guard let store, !threadIDs.isEmpty else { return 0 }
        do {
            let removed = try await store.removeThreads(threadIDs, from: id)
            await refresh()
            return removed
        } catch {
            actionError = String(describing: error)
            return 0
        }
    }

    /// What a rule would add, for the editor's live preview; nil for a rule with no conditions.
    /// Errors are the editor's to show beside the rule.
    func preview(_ rule: SpaceRule, for id: MailSpaceID?) async throws -> SpaceRulePreview? {
        guard let store, !rule.isEmpty else { return nil }
        return try await store.previewRule(rule, for: id)
    }

    /// The spaces a message is in.
    func spaces(containing message: MailMessageID) async -> [MailSpace] {
        guard let store else { return [] }
        do {
            let ids = try await store.spaces(containing: message)
            return spaces.filter { ids.contains($0.id) }
        } catch {
            actionError = String(describing: error)
            return []
        }
    }
}
