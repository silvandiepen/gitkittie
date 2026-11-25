import Foundation
import MailCore

/// The Files app (and any app with access to On My iPhone) can add or remove `.eml` files in
/// the mail folder while Mail is suspended (MAIL-051). The index is rebuildable from the folder
/// (MAIL-005), so when the app becomes active it counts the originals the way a rebuild reads
/// them and rebuilds when the index holds a different number.
///
/// A count is cheap (a directory walk, no file is read) and catches what Files can do: copy
/// messages in, delete them. An original edited in place keeps the count; the store's hash
/// check reports it when the message is read (`verifyIntegrity`), and never repairs it.
enum MailFolderCheck {
    /// The `.eml` originals a rebuild would index: `accounts/<id>/messages/<year>/<month>/<uuid>.eml`.
    static func originalCount(in mailFolder: URL, fileManager: FileManager = .default) -> Int {
        let accounts = mailFolder.appendingPathComponent("accounts", isDirectory: true)
        var count = 0
        for account in contents(of: accounts, fileManager) {
            let messages = account.appendingPathComponent("messages", isDirectory: true)
            for year in contents(of: messages, fileManager) where Int(year.lastPathComponent) != nil {
                for month in contents(of: year, fileManager) where Int(month.lastPathComponent) != nil {
                    count += contents(of: month, fileManager).filter { file in
                        let name = file.deletingPathExtension().lastPathComponent
                        return file.pathExtension == "eml" && MailMessageID(name)?.rawValue == name
                    }.count
                }
            }
        }
        return count
    }

    /// True when the folder and the index disagree, so the index should be made again.
    static func needsRebuild(mailFolder: URL, indexedCount: Int) -> Bool {
        originalCount(in: mailFolder) != indexedCount
    }

    private static func contents(of folder: URL, _ fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }
}
