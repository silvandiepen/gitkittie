import Foundation
import MailCore
import MailStore

/// What an import did.
struct ImportReport: Equatable {
    var imported = 0
    /// Files whose exact bytes were already stored.
    var duplicates = 0
    /// Files that are not messages, too large, or unreadable: names only, for the notice.
    var skipped: [String] = []

    var summary: String {
        var parts = ["\(imported) \(imported == 1 ? "message" : "messages") imported"]
        if duplicates > 0 { parts.append("\(duplicates) already here") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped (not a message or unreadable)") }
        return parts.joined(separator: ", ") + "."
    }
}

/// File ▸ Import Messages… (GKM-012): `.eml` files, or folders of them, go into a local
/// "On My Mac" account. Nothing is uploaded anywhere; the files are stored like synced mail
/// (original + Markdown in the mail folder) and arrive marked as read.
enum MailImporter {
    static let account = MailAccount(id: MailAccountID("on-my-mac"), displayName: "On My Mac", address: "")
    /// Larger files are not read: a message this size is almost certainly not mail.
    static let maximumFileSize = 100 * 1024 * 1024
    /// Most files taken from one import.
    static let maximumFiles = 200_000

    static func importMessages(from urls: [URL], into store: MailStore) async -> ImportReport {
        var report = ImportReport()
        var accountSaved = false
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            for file in emlFiles(at: url) {
                do {
                    let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= maximumFileSize else { report.skipped.append(file.lastPathComponent); continue }
                    let data = try Data(contentsOf: file)
                    if !accountSaved {
                        try await store.save(account)
                        accountSaved = true
                    }
                    if try await store.containsOriginal(data, account: account.id) {
                        report.duplicates += 1
                        continue
                    }
                    try await store.ingest(data, account: account.id, flags: MessageFlags(seen: true))
                    report.imported += 1
                } catch {
                    report.skipped.append(file.lastPathComponent)
                }
            }
        }
        return report
    }

    /// The `.eml` files at `url`: the file itself, or every one under a folder (hidden files
    /// and packages skipped, symbolic links not followed), by path, at most `maximumFiles`.
    static func emlFiles(at url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { return [] }
        if values.isRegularFile == true { return url.pathExtension.lowercased() == "eml" ? [url] : [] }
        guard values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "eml",
                  let fileValues = try? file.resourceValues(forKeys: Set(keys)),
                  fileValues.isRegularFile == true, fileValues.isSymbolicLink != true else { continue }
            files.append(file)
            if files.count >= maximumFiles { break }
        }
        return files.sorted { $0.path < $1.path }
    }
}
