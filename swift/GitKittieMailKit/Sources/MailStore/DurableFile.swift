import Foundation

/// The store's atomic, fsynced file write, for the other parts of the app that keep files of
/// their own next to the mail: drafts (`Mail/drafts/`) and the outbox journal
/// (`<Application Support>/Mail/state/outbox/`). A reader sees the old file or the new one,
/// never a torn one, and a completed write survives a crash or power loss.
public enum DurableFile {
    public static func write(_ data: Data, to destination: URL) throws {
        try AtomicWriter(faults: .none).write(data, to: destination)
    }

    /// Removes temporary files an interrupted write left in `directory` (not recursive).
    public static func removePartials(in directory: URL) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(AtomicWriter.partialSuffix) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Flushes a directory, so a rename or removal in it is durable.
    public static func syncDirectory(_ directory: URL) throws {
        try AtomicWriter.syncDirectory(directory)
    }

    /// A single path segment the app made itself (a UUID, an id): letters, digits, `-` and `_`.
    /// Anything else, including `..` and separators, is refused.
    public static func checkedComponent(_ value: String) throws -> String {
        try SafePath.component(value)
    }
}

extension StoreLocations {
    /// `Mail/drafts/`: drafts are the user's, so they live in the mail folder and travel with it.
    public var draftsFolder: URL { mailFolder.appendingPathComponent("drafts", isDirectory: true) }

    /// `<Application Support>/Mail/state/outbox/`: the outbox journal is this device's
    /// commitment to send, never synced (two devices must never both own a send).
    public var outboxFolder: URL {
        deviceFolder.appendingPathComponent("state", isDirectory: true).appendingPathComponent("outbox", isDirectory: true)
    }

    /// `<Application Support>/Mail/state/device-id`: a random id for this installation, so
    /// drafts can say which device last wrote them.
    public func deviceIdentifier() throws -> String {
        let url = deviceFolder.appendingPathComponent("state/device-id")
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           (try? SafePath.component(existing)) != nil {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        try DurableFile.write(Data(id.utf8), to: url)
        return id
    }
}
