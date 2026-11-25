import Foundation
@testable import GitKanbanKit

/// Storage a test owns and removes again: a defaults suite (and the file macOS keeps it in),
/// and a temporary folder for the outbox and read cache. Never the App Group container: macOS makes that folder, under
/// ~/Library/Group Containers, the first time it is asked for one, and nothing removes it.
extension AppModel {
    static func testing(suite: String, keychainService: String) -> AppModel {
        AppModel(appGroup: suite, keychainService: keychainService, migratesLegacyStorage: false,
                 storageDirectory: testStorage(suite))
    }

    static func testStorage(_ suite: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    }

    static func removeTestStorage(_ suite: String) {
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        // An emptied suite still leaves its file behind; written out first, then removed.
        defaults?.synchronize()
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: preferences)
        try? FileManager.default.removeItem(at: testStorage(suite))
    }
}
