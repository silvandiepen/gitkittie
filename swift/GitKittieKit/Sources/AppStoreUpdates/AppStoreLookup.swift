import Foundation

/// Which App Store an app is sold in. A universal purchase has one record per platform under
/// the same bundle id, each with its own version and minimum system.
public enum AppStorePlatform: Sendable {
    case iOS
    case macOS

    /// The platform this code is running on. Mac Catalyst and iPad apps on a Mac use the iOS record.
    public static var current: AppStorePlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

/// What the App Store says about the newest version of an app.
public struct AppStoreRelease: Equatable, Sendable, Codable {
    /// The version in the store, as the store writes it.
    public let version: String
    /// The App Store id, for the link to the app's page.
    public let trackID: Int
    /// The oldest system that can install this version, when the store says.
    public let minimumOSVersion: String?

    public init(version: String, trackID: Int, minimumOSVersion: String?) {
        self.version = version
        self.trackID = trackID
        self.minimumOSVersion = minimumOSVersion
    }
}

/// Apple's public lookup endpoint: no account, no key, no tracking. The only things sent are
/// the bundle id and the store country.
public enum AppStoreLookup {
    /// `https://itunes.apple.com/lookup?bundleId=<id>&country=<cc>`. On the Mac it asks for the
    /// Mac record (`entity=desktopSoftware`); without it a universal purchase answers with the
    /// iPhone version and the iOS minimum.
    public static func url(bundleID: String, country: String?, platform: AppStorePlatform) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        var items = [URLQueryItem(name: "bundleId", value: bundleID)]
        if let country { items.append(URLQueryItem(name: "country", value: country)) }
        if platform == .macOS { items.append(URLQueryItem(name: "entity", value: "desktopSoftware")) }
        components.queryItems = items
        return components.url!
    }

    /// The app's page in the App Store app.
    public static func storeURL(trackID: Int, platform: AppStorePlatform) -> URL {
        switch platform {
        case .iOS: URL(string: "itms-apps://apps.apple.com/app/id\(trackID)")!
        case .macOS: URL(string: "macappstore://apps.apple.com/app/id\(trackID)")!
        }
    }

    /// A store country for the lookup: the two-letter region of this device's locale, or nil
    /// when it has none (then Apple answers for the US store).
    public static func country(for locale: Locale = .current) -> String? {
        guard let region = locale.region?.identifier, region.count == 2, region.allSatisfy(\.isLetter) else { return nil }
        return region.lowercased()
    }

    /// Reads a lookup answer. Nil when the app is not in that store (Apple answers with no results).
    public static func release(from data: Data, bundleID: String) throws -> AppStoreRelease? {
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        guard let match = answer.results.first(where: { $0.bundleId == bundleID }) else { return nil }
        return AppStoreRelease(version: match.version, trackID: match.trackId, minimumOSVersion: match.minimumOsVersion)
    }

    private struct Answer: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let bundleId: String
        let version: String
        let trackId: Int
        let minimumOsVersion: String?
    }
}
