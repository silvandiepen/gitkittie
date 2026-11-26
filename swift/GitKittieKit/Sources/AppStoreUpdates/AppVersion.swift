import Foundation

/// A dotted version number, `1.3.0`, compared part by part as numbers: `1.10` is newer than
/// `1.9`, and `1.3` is the same version as `1.3.0`.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// The numbers, without trailing zeros (`1.3.0` keeps `[1, 3]`), so equal versions compare equal.
    public let parts: [Int]
    /// The version as it was written, for showing to people.
    public let description: String

    /// Reads `1`, `1.3` or `1.3.0`. Anything else (a letter, a suffix, an empty part) is not a
    /// version we can compare, and gives nil.
    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var numbers: [Int] = []
        for piece in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let number = Int(piece), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        parts = numbers
        description = text
    }

    /// The version of the system this runs on.
    public init(_ os: OperatingSystemVersion) {
        self.init("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")!
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.parts == rhs.parts }
    public func hash(into hasher: inout Hasher) { hasher.combine(parts) }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
