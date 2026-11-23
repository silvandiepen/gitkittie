import Foundation
import Network
import Observation

/// A GitKanban folder server found on the local network.
///
/// The server announces itself with Bonjour (`_gitkanban._tcp`); its TXT record carries
/// the address the app should use (normally the Mac's Tailscale HTTPS name), so the
/// server never has to listen on the LAN itself.
public struct DiscoveredServer: Identifiable, Hashable, Sendable {
    public static let serviceType = "_gitkanban._tcp"

    /// The Bonjour instance name, e.g. "Projects on Sil's MacBook Pro". Unique on the network.
    public let name: String
    /// The served folder's name.
    public let root: String?
    /// The address to connect to. `nil` while the server has no reachable address
    /// (Tailscale not running on the Mac).
    public let url: String?

    public var id: String { name }

    public init(name: String, txt: [String: String]) {
        self.name = name
        let root = txt["root"]?.trimmingCharacters(in: .whitespaces)
        self.root = root?.isEmpty == false ? root : nil
        let url = txt["url"]?.trimmingCharacters(in: .whitespaces)
        if let url, !url.isEmpty, let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true, parsed.host != nil {
            self.url = url
        } else {
            self.url = nil
        }
    }
}

/// Browses the local network for GitKanban folder servers while it's started.
@MainActor
@Observable
public final class FolderServerBrowser {
    public private(set) var servers: [DiscoveredServer] = []
    /// Set when browsing can't run (e.g. local network access denied).
    public private(set) var problem: String?
    public private(set) var isBrowsing = false

    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        problem = nil
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: DiscoveredServer.serviceType, domain: nil),
                                using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.servers(from: results)
            MainActor.assumeIsolated { self?.servers = found }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        self.browser = browser
        isBrowsing = true
        // Handlers run on the main queue, which is what `assumeIsolated` relies on.
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error):
            problem = Self.describe(error)
            stop()
        case .waiting(let error):
            problem = Self.describe(error)
        case .ready:
            problem = nil
        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    private static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
            return "Local network access is off for GitKanban. Turn it on in Settings › Privacy & Security › Local Network to find servers."
        }
        return "Can't search the local network: \(error.localizedDescription)"
    }

    nonisolated private static func servers(from results: Set<NWBrowser.Result>) -> [DiscoveredServer] {
        var byName: [String: DiscoveredServer] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                for key in ["root", "url"] {
                    if let value = record[key] { txt[key] = value }
                }
            }
            let server = DiscoveredServer(name: name, txt: txt)
            // The same service shows up once per interface; keep the one with an address.
            if byName[name]?.url == nil { byName[name] = server }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
