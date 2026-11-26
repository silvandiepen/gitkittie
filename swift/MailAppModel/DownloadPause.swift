import Foundation

/// Downloading is paused because the disk that holds the mail folder is nearly full (MAIL-106,
/// GKM-090). The sync looks at the free space when it starts, as mail comes in and once a
/// minute, pauses under the minimum and carries on by itself when there is room again. Mail
/// already stored is never removed to make room: it is the person's (MAIL-003).
///
/// The Mac pauses below 2 GB (Sil, GKM-067); the iPhone and iPad below their storage budget's
/// minimum (MAIL-051, 1 GB). Both say so in the same words.
struct DownloadPause: Equatable, Sendable {
    /// Free space on the mail folder's disk when the sync last looked.
    var freeBytes: Int64
    /// The free space under which downloading pauses.
    var minimumFreeBytes: Int64

    /// The Mac's minimum: 2 GB, as Finder counts (MAIL-106).
    static let macMinimumFreeBytes: Int64 = 2_000_000_000

    /// "Downloading paused: only 0.9 GB free on this Mac. It carries on by itself when there is room."
    var text: String {
        "Downloading paused: only \(Self.amount(freeBytes)) free on \(DeviceWords.this). It carries on by itself when there is room."
    }

    /// The status line's short form, beside each account.
    static let shortText = "Downloading paused · disk nearly full"

    /// Free space as people read it on the device: GB with one decimal, MB under 0.1 GB.
    static func amount(_ bytes: Int64) -> String {
        let gigabytes = Double(max(0, bytes)) / 1_000_000_000
        if gigabytes >= 0.1 {
            return gigabytes.formatted(.number.precision(.fractionLength(1))) + " GB"
        }
        return (Double(max(0, bytes)) / 1_000_000).formatted(.number.precision(.fractionLength(0))) + " MB"
    }
}
