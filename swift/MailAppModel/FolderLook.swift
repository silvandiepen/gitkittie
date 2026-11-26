/// A folder's symbol and a special role's name, for the sidebars and Settings on both platforms
/// (SF Symbols names; no UI framework needed).
enum FolderLook {
    static func icon(_ role: String?) -> String {
        switch role {
        case "inbox": "tray"
        case "sent": "paperplane"
        case "drafts": "doc"
        case "archive": "archivebox"
        case "trash": "trash"
        case "junk": "xmark.bin"
        case "flagged": "flag"
        case "all": "tray.2"
        default: "folder"
        }
    }

    static func title(_ role: String) -> String {
        switch role {
        case "inbox": "Inbox"
        case "sent": "Sent"
        case "drafts": "Drafts"
        case "archive": "Archive"
        case "trash": "Trash"
        case "junk": "Junk"
        case "flagged": "Flagged"
        case "all": "All Mail"
        default: role.prefix(1).uppercased() + role.dropFirst()
        }
    }
}
