import Foundation

/// A newer version this device can install, and where to get it.
public struct UpdateOffer: Equatable, Sendable {
    /// The new version, as the store writes it.
    public let version: String
    /// The app's page in the App Store app.
    public let storeURL: URL

    public init(version: String, storeURL: URL) {
        self.version = version
        self.storeURL = storeURL
    }
}

/// Asks the App Store at most once a day whether a newer version is out, and remembers which
/// version the person said "not now" to.
///
/// Quiet by design: offline, a refused or unreadable answer, or an app that is not in the store
/// all mean no offer. The last answer is kept, so an offer found this morning still shows after
/// a relaunch this afternoon without asking again.
@MainActor
public final class UpdateChecker {
    /// How long one answer is trusted before the store is asked again.
    public nonisolated static let interval: TimeInterval = 24 * 60 * 60

    /// Gets the bytes at a URL. The real one is `UpdateChecker.download`.
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let bundleID: String
    private let installedVersion: AppVersion
    private let platform: AppStorePlatform
    private let osVersion: AppVersion
    private let country: String?
    private let defaults: UserDefaults
    private let fetch: Fetch

    public init(bundleID: String, installedVersion: AppVersion, platform: AppStorePlatform = .current,
                osVersion: AppVersion = AppVersion(ProcessInfo.processInfo.operatingSystemVersion),
                country: String? = AppStoreLookup.country(), defaults: UserDefaults = .standard,
                fetch: @escaping Fetch = UpdateChecker.download) {
        self.bundleID = bundleID
        self.installedVersion = installedVersion
        self.platform = platform
        self.osVersion = osVersion
        self.country = country
        self.defaults = defaults
        self.fetch = fetch
    }

    /// A checker for the running app, from its bundle id and `CFBundleShortVersionString`.
    /// Nil when the bundle has neither.
    public convenience init?(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        guard let bundleID = bundle.bundleIdentifier,
              let text = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = AppVersion(text) else { return nil }
        self.init(bundleID: bundleID, installedVersion: version, defaults: defaults)
    }

    // MARK: Checking

    /// The offer to show now, asking the store first when the last answer is a day old.
    public func check(now: Date = Date()) async -> UpdateOffer? {
        if Self.isDue(lastChecked: defaults.object(forKey: Keys.lastChecked) as? Date, now: now) {
            let url = AppStoreLookup.url(bundleID: bundleID, country: country, platform: platform)
            do {
                // Nil when the app is not in this store (yet): that clears an old offer.
                store(try AppStoreLookup.release(from: try await fetch(url), bundleID: bundleID))
                defaults.set(now, forKey: Keys.lastChecked)
            } catch {
                // Offline, refused or unreadable: by design no alert and no offer change. The
                // check is not recorded, so the next launch asks again.
            }
        }
        return currentOffer()
    }

    /// The offer from the last answer, without asking the store.
    public func currentOffer() -> UpdateOffer? {
        guard let release = storedRelease(),
              let offer = Self.offer(for: release, installed: installedVersion, os: osVersion, platform: platform),
              offer.version != defaults.string(forKey: Keys.dismissed) else { return nil }
        return offer
    }

    /// "Not now" for this version. A later version is offered again.
    public func dismiss(_ offer: UpdateOffer) {
        defaults.set(offer.version, forKey: Keys.dismissed)
    }

    // MARK: Rules

    /// Whether the last answer is old enough to ask again. A check dated in the future (the clock
    /// was set back) counts as due, so a wrong clock cannot silence the check for good.
    public nonisolated static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        let age = now.timeIntervalSince(lastChecked)
        return age < 0 || age >= interval
    }

    /// An offer when the store's version is newer than the installed one and this system can
    /// install it. A version or minimum the store writes in a way we cannot read gives no offer.
    public nonisolated static func offer(for release: AppStoreRelease, installed: AppVersion, os: AppVersion,
                                         platform: AppStorePlatform) -> UpdateOffer? {
        guard let available = AppVersion(release.version), available > installed else { return nil }
        if let minimum = release.minimumOSVersion {
            guard let required = AppVersion(minimum), os >= required else { return nil }
        }
        return UpdateOffer(version: release.version, storeURL: AppStoreLookup.storeURL(trackID: release.trackID, platform: platform))
    }

    // MARK: Network

    /// One GET with an ephemeral session: no cookies, no cache, nothing kept.
    public nonisolated static let download: Fetch = { url in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: Storage

    private enum Keys {
        static let lastChecked = "appStoreUpdate.lastChecked"
        static let release = "appStoreUpdate.release"
        static let dismissed = "appStoreUpdate.dismissedVersion"
    }

    private func store(_ release: AppStoreRelease?) {
        if let release, let data = try? JSONEncoder().encode(release) {
            defaults.set(data, forKey: Keys.release)
        } else {
            defaults.removeObject(forKey: Keys.release)
        }
    }

    private func storedRelease() -> AppStoreRelease? {
        guard let data = defaults.data(forKey: Keys.release) else { return nil }
        return try? JSONDecoder().decode(AppStoreRelease.self, from: data)
    }
}
