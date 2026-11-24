import CryptoKit
import Foundation

/// The two places the store uses (Architecture.md, Storage and identity; MAIL-013):
///
/// - `mailFolder` (`Mail/`): only what the user owns and may sync, back up or version —
///   `accounts/<account-id>/messages/<yyyy>/<mm>/<local-id>.eml` and `.md`, `blobs/<sha256>`,
///   `accounts/<account-id>/account.json`, and `layout.json`.
/// - `deviceFolder` (`<Application Support>/Mail/`): device-local and never synced —
///   `index.sqlite`, `state/<account-id>/sync.sqlite`, `state/journal/`, `cache/`.
public struct StoreLocations: Sendable, Equatable {
    public var mailFolder: URL
    public var deviceFolder: URL

    public init(mailFolder: URL, deviceFolder: URL) {
        self.mailFolder = mailFolder
        self.deviceFolder = deviceFolder
    }

    /// The app's defaults: `Documents/Mail` for the mail and `Application Support/Mail` for the
    /// device state. In the sandboxed app both resolve inside its container.
    public static func standard(fileManager: FileManager = .default) throws -> StoreLocations {
        let documents = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return StoreLocations(mailFolder: documents.appendingPathComponent("Mail", isDirectory: true),
                              deviceFolder: support.appendingPathComponent("Mail", isDirectory: true))
    }

    var indexURL: URL { deviceFolder.appendingPathComponent("index.sqlite") }
    var journalFolder: URL { deviceFolder.appendingPathComponent("state/journal", isDirectory: true) }
    var cacheFolder: URL { deviceFolder.appendingPathComponent("cache", isDirectory: true) }
    var blobsFolder: URL { mailFolder.appendingPathComponent("blobs", isDirectory: true) }
    var accountsFolder: URL { mailFolder.appendingPathComponent("accounts", isDirectory: true) }
    var layoutURL: URL { mailFolder.appendingPathComponent("layout.json") }

    func stateFolder(_ account: String) -> URL {
        deviceFolder.appendingPathComponent("state", isDirectory: true).appendingPathComponent(account, isDirectory: true)
    }

    /// Neither folder may sit inside the other: then the device state could reach a synced or
    /// versioned mail folder, or the mail could be mistaken for disposable state.
    func validate() throws {
        if SafePath.isContained(deviceFolder, in: mailFolder) || SafePath.isContained(mailFolder, in: deviceFolder) {
            throw MailStoreError.deviceStateInsideMailFolder
        }
    }
}

enum Hashing {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
