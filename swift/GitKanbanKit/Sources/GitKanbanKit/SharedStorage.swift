import Foundation

/// Where GitKanban iOS keeps the state its share extension also needs. The app and the
/// extension both belong to this App Group; the group id doubles as the keychain access
/// group for the provider token.
public enum GitKanbanSharedStorage {
    public static let appGroup = "group.app.hakobs.gitkanban"
    /// Deliberately not the app's bundle id: the pre-App-Group token lives under that
    /// service name, and an unscoped query for it must not match the shared item.
    public static let keychainService = "app.hakobs.gitkanban.shared"
}

public extension AppModel {
    /// The model over the shared App Group storage. `migratesLegacyStorage` is true in the
    /// app and false in the extension (which has no earlier private storage of its own).
    @MainActor
    static func shared(migratesLegacyStorage: Bool) -> AppModel {
        AppModel(appGroup: GitKanbanSharedStorage.appGroup,
                 keychainService: GitKanbanSharedStorage.keychainService,
                 migratesLegacyStorage: migratesLegacyStorage)
    }
}
