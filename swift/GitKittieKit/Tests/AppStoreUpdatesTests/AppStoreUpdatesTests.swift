import Foundation
import Testing
@testable import AppStoreUpdates

// The fixtures are real answers from Apple's lookup endpoint, recorded once with curl on
// 2026-11-26 (Tasks 1.3.0 in the Dutch store, iPhone and Mac records; Mail, not listed):
//   curl --compressed "https://itunes.apple.com/lookup?bundleId=app.hakobs.gitkanban&country=nl"
//   curl --compressed "https://itunes.apple.com/lookup?bundleId=app.hakobs.gitkanban&country=nl&entity=desktopSoftware"
//   curl --compressed "https://itunes.apple.com/lookup?bundleId=app.hakobs.gitmail&country=nl"

private let tasksID = "app.hakobs.gitkanban"

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func version(_ text: String) -> AppVersion { AppVersion(text)! }

// MARK: - Versions

struct AppVersionTests {
    @Test func comparesPartsAsNumbers() {
        #expect(version("1.10") > version("1.9"))
        #expect(version("1.3.1") > version("1.3.0"))
        #expect(version("2.0") > version("1.99.99"))
        #expect(version("1.2.9") < version("1.3"))
    }

    @Test func equalVersionsAreEqual() {
        #expect(version("1.3") == version("1.3.0"))
        #expect(version("1.3.0.0") == version("1.3"))
        #expect(!(version("1.3") < version("1.3.0")))
        #expect(!(version("1.3.0") > version("1.3")))
        #expect(Set([version("1.3"), version("1.3.0")]).count == 1)
    }

    @Test func olderIsOlder() {
        #expect(version("1.2.0") < version("1.3.0"))
        #expect(version("0.9") < version("1"))
    }

    @Test func keepsHowItWasWritten() {
        #expect(version(" 1.3.0 ").description == "1.3.0")
    }

    @Test func refusesWhatIsNotAVersion() {
        for text in ["", "1.3b", "1..2", "1.", "-1", "v1.2", "1.2-beta", "١.٢"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func readsTheSystemVersion() {
        #expect(AppVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)) == version("26.1"))
    }
}

// MARK: - Lookup

struct AppStoreLookupTests {
    @Test func readsTheRecordedIPhoneAnswer() throws {
        let release = try #require(try AppStoreLookup.release(from: fixture("lookup-tasks-ios-nl"), bundleID: tasksID))
        #expect(release == AppStoreRelease(version: "1.3.0", trackID: 6_792_793_088, minimumOSVersion: "17.0"))
    }

    @Test func readsTheRecordedMacAnswer() throws {
        let release = try #require(try AppStoreLookup.release(from: fixture("lookup-tasks-mac-nl"), bundleID: tasksID))
        #expect(release == AppStoreRelease(version: "1.3.0", trackID: 6_792_793_088, minimumOSVersion: "14.0"))
    }

    @Test func anAppNotInTheStoreIsNil() throws {
        #expect(try AppStoreLookup.release(from: fixture("lookup-mail-not-listed"), bundleID: "app.hakobs.gitmail") == nil)
    }

    @Test func anotherAppsRecordIsNotOurs() throws {
        #expect(try AppStoreLookup.release(from: fixture("lookup-tasks-ios-nl"), bundleID: "app.hakobs.gitmail") == nil)
    }

    @Test func anUnreadableAnswerThrows() {
        #expect(throws: (any Error).self) { try AppStoreLookup.release(from: Data("<html>".utf8), bundleID: tasksID) }
    }

    @Test func sendsOnlyTheBundleIDAndCountry() {
        #expect(AppStoreLookup.url(bundleID: tasksID, country: "nl", platform: .iOS).absoluteString
                == "https://itunes.apple.com/lookup?bundleId=app.hakobs.gitkanban&country=nl")
        #expect(AppStoreLookup.url(bundleID: tasksID, country: "nl", platform: .macOS).absoluteString
                == "https://itunes.apple.com/lookup?bundleId=app.hakobs.gitkanban&country=nl&entity=desktopSoftware")
        #expect(AppStoreLookup.url(bundleID: tasksID, country: nil, platform: .iOS).absoluteString
                == "https://itunes.apple.com/lookup?bundleId=app.hakobs.gitkanban")
    }

    @Test func opensTheStorePageForThePlatform() {
        #expect(AppStoreLookup.storeURL(trackID: 6_792_793_088, platform: .iOS).absoluteString == "itms-apps://apps.apple.com/app/id6792793088")
        #expect(AppStoreLookup.storeURL(trackID: 6_792_793_088, platform: .macOS).absoluteString == "macappstore://apps.apple.com/app/id6792793088")
    }

    @Test func takesTheCountryFromTheLocaleRegion() {
        #expect(AppStoreLookup.country(for: Locale(identifier: "nl_NL")) == "nl")
        #expect(AppStoreLookup.country(for: Locale(identifier: "en_US")) == "us")
        #expect(AppStoreLookup.country(for: Locale(identifier: "en_001")) == nil)
    }
}

// MARK: - Offer and the minimum system

struct UpdateOfferTests {
    private let release = AppStoreRelease(version: "1.3.0", trackID: 6_792_793_088, minimumOSVersion: "17.0")

    @Test func offersANewerVersion() {
        let offer = UpdateChecker.offer(for: release, installed: version("1.2.0"), os: version("18.1"), platform: .iOS)
        #expect(offer == UpdateOffer(version: "1.3.0", storeURL: URL(string: "itms-apps://apps.apple.com/app/id6792793088")!))
    }

    @Test func noOfferForTheSameOrAnOlderStoreVersion() {
        #expect(UpdateChecker.offer(for: release, installed: version("1.3"), os: version("18.1"), platform: .iOS) == nil)
        #expect(UpdateChecker.offer(for: release, installed: version("1.4.0"), os: version("18.1"), platform: .iOS) == nil)
    }

    @Test func noOfferWhenThisSystemCannotInstallIt() {
        #expect(UpdateChecker.offer(for: release, installed: version("1.2.0"), os: version("16.7.10"), platform: .iOS) == nil)
        #expect(UpdateChecker.offer(for: release, installed: version("1.2.0"), os: version("17.0"), platform: .iOS) != nil)
    }

    @Test func theMacRecordHasItsOwnMinimum() throws {
        let mac = try #require(try AppStoreLookup.release(from: fixture("lookup-tasks-mac-nl"), bundleID: tasksID))
        let offer = UpdateChecker.offer(for: mac, installed: version("1.2.0"), os: version("14.0"), platform: .macOS)
        #expect(offer?.storeURL.absoluteString == "macappstore://apps.apple.com/app/id6792793088")
        #expect(UpdateChecker.offer(for: mac, installed: version("1.2.0"), os: version("13.6"), platform: .macOS) == nil)
    }

    @Test func noMinimumMeansAnySystem() {
        let open = AppStoreRelease(version: "1.3.0", trackID: 1, minimumOSVersion: nil)
        #expect(UpdateChecker.offer(for: open, installed: version("1.2.0"), os: version("1.0"), platform: .iOS) != nil)
    }

    @Test func anUnreadableStoreVersionOrMinimumOffersNothing() {
        let odd = AppStoreRelease(version: "1.3 beta", trackID: 1, minimumOSVersion: "17.0")
        #expect(UpdateChecker.offer(for: odd, installed: version("1.2.0"), os: version("18.0"), platform: .iOS) == nil)
        let oddMinimum = AppStoreRelease(version: "1.3.0", trackID: 1, minimumOSVersion: "seventeen")
        #expect(UpdateChecker.offer(for: oddMinimum, installed: version("1.2.0"), os: version("18.0"), platform: .iOS) == nil)
    }
}

// MARK: - Throttle, offline, dismissal

/// Answers the lookup with recorded bytes and counts the requests; the network edge only.
private actor Store {
    var answer: Result<Data, URLError>
    private(set) var requests: [URL] = []
    init(_ answer: Result<Data, URLError>) { self.answer = answer }
    func set(_ answer: Result<Data, URLError>) { self.answer = answer }
    func get(_ url: URL) throws -> Data {
        requests.append(url)
        return try answer.get()
    }
}

@MainActor
struct UpdateCheckerTests {
    private let defaults: UserDefaults
    private let start = Date(timeIntervalSince1970: 1_795_000_000)

    init() {
        let suite = "git094-updates-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func checker(_ store: Store, installed: String = "1.2.0", os: String = "18.1") -> UpdateChecker {
        UpdateChecker(bundleID: tasksID, installedVersion: version(installed), platform: .iOS, osVersion: version(os),
                      country: "nl", defaults: defaults, fetch: { try await store.get($0) })
    }

    @Test func isDueOncePerDay() {
        #expect(UpdateChecker.isDue(lastChecked: nil, now: start))
        #expect(!UpdateChecker.isDue(lastChecked: start, now: start))
        #expect(!UpdateChecker.isDue(lastChecked: start, now: start.addingTimeInterval(23 * 3600 + 3599)))
        #expect(UpdateChecker.isDue(lastChecked: start, now: start.addingTimeInterval(24 * 3600)))
        #expect(UpdateChecker.isDue(lastChecked: start.addingTimeInterval(3600), now: start))
    }

    @Test func asksAtMostOnceADayAndKeepsTheOfferMeanwhile() async throws {
        let store = Store(.success(try fixture("lookup-tasks-ios-nl")))
        let first = await checker(store).check(now: start)
        #expect(first?.version == "1.3.0")
        #expect(await store.requests.count == 1)

        // A relaunch the same afternoon: no request, the same offer.
        let later = await checker(store).check(now: start.addingTimeInterval(6 * 3600))
        #expect(later == first)
        #expect(await store.requests.count == 1)

        _ = await checker(store).check(now: start.addingTimeInterval(24 * 3600))
        #expect(await store.requests.count == 2)
        #expect(await store.requests.first?.absoluteString == "https://itunes.apple.com/lookup?bundleId=app.hakobs.gitkanban&country=nl")
    }

    @Test func offlineIsQuietAndAsksAgainNextTime() async throws {
        let store = Store(.failure(URLError(.notConnectedToInternet)))
        #expect(await checker(store).check(now: start) == nil)
        await store.set(.success(try fixture("lookup-tasks-ios-nl")))
        #expect(await checker(store).check(now: start.addingTimeInterval(60))?.version == "1.3.0")
        #expect(await store.requests.count == 2)
    }

    @Test func offlineKeepsAnOfferAlreadyFound() async throws {
        let store = Store(.success(try fixture("lookup-tasks-ios-nl")))
        _ = await checker(store).check(now: start)
        await store.set(.failure(URLError(.notConnectedToInternet)))
        #expect(await checker(store).check(now: start.addingTimeInterval(25 * 3600))?.version == "1.3.0")
    }

    @Test func notInTheStoreIsQuiet() async throws {
        let store = Store(.success(try fixture("lookup-mail-not-listed")))
        #expect(await checker(store).check(now: start) == nil)
        #expect(await store.requests.count == 1)
    }

    @Test func afterUpdatingTheOfferGoes() async throws {
        let store = Store(.success(try fixture("lookup-tasks-ios-nl")))
        #expect(await checker(store, installed: "1.2.0").check(now: start) != nil)
        #expect(await checker(store, installed: "1.3.0").check(now: start.addingTimeInterval(60)) == nil)
    }

    @Test func aDeviceThatCannotInstallItSeesNothing() async throws {
        let store = Store(.success(try fixture("lookup-tasks-ios-nl")))
        #expect(await checker(store, os: "16.7").check(now: start) == nil)
    }

    @Test func dismissalHoldsForThatVersionOnly() async throws {
        let recorded = try fixture("lookup-tasks-ios-nl")
        let store = Store(.success(recorded))
        let checker = checker(store)
        let offer = try #require(await checker.check(now: start))
        checker.dismiss(offer)
        #expect(checker.currentOffer() == nil)
        #expect(await self.checker(store).check(now: start.addingTimeInterval(60)) == nil)

        // The next day the store has 1.4.0: that one is offered.
        let newer = String(decoding: recorded, as: UTF8.self).replacingOccurrences(of: "\"version\":\"1.3.0\"", with: "\"version\":\"1.4.0\"")
        #expect(newer.contains("\"version\":\"1.4.0\""))
        await store.set(.success(Data(newer.utf8)))
        #expect(await self.checker(store).check(now: start.addingTimeInterval(24 * 3600))?.version == "1.4.0")
    }
}

// MARK: - Distribution

/// Which copies may ask StoreKit for the app transaction. Asking in a copy without a receipt
/// makes macOS show "Sign in to your Apple Account" (GITKITTIE-110), so only a production receipt
/// with content may.
struct AppDistributionTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tmac-receipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func noReceiptURLIsMissing() {
        #expect(AppDistribution.receipt(at: nil) == .missing)
    }

    @Test func aMacBuildWithoutAReceiptIsMissing() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // A team-signed Release build: the URL is there, the file is not.
        #expect(AppDistribution.receipt(at: root.appendingPathComponent("Contents/_MASReceipt/receipt")) == .missing)
    }

    @Test func anEmptyReceiptIsMissing() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("receipt")
        try Data().write(to: receipt)
        #expect(AppDistribution.receipt(at: receipt) == .missing)
    }

    @Test func aFolderNamedReceiptIsMissing() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("receipt")
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
        #expect(AppDistribution.receipt(at: receipt) == .missing)
    }

    @Test func aSandboxReceiptIsSandboxWhetherOrNotItExists() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("sandboxReceipt")
        #expect(AppDistribution.receipt(at: receipt) == .sandbox)
        try Data([1, 2, 3]).write(to: receipt)
        #expect(AppDistribution.receipt(at: receipt) == .sandbox)
    }

    @Test func aProductionReceiptWithContentIsProduction() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("receipt")
        try Data([0x30, 0x80]).write(to: receipt)
        #expect(AppDistribution.receipt(at: receipt) == .production)
    }

    /// The whole check on a Mac app bundle with no receipt answers without asking StoreKit.
    @Test func aBundleWithoutAReceiptIsNotFromTheAppStore() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("tmac.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "app.hakobs.tmac", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: app))
        #expect(AppDistribution.receipt(at: bundle.appStoreReceiptURL) == .missing)
        #expect(await AppDistribution.isAppStore(bundle: bundle) == false)
    }
}
