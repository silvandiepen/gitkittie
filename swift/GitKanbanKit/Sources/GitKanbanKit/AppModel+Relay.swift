import Foundation
import GitKittieKit

// Turning live updates on and off for a repo. See `Relay.swift`.

extension AppModel {
    private var relayURLKey: String { "gitkanban.relayURL" }

    /// The GitKittie relay (`apps/gitkanban-relay`, deployed), offered until another is entered.
    public static let defaultRelayURL = "https://gitkanban-relay.vandipyan.workers.dev"

    /// The relay this device registers new channels with. Repos that already have a
    /// channel carry their relay's address in `.gitkanban/relay.json`.
    public var relayURL: String {
        get { defaults.string(forKey: relayURLKey) ?? Self.defaultRelayURL }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: relayURLKey) }
    }

    /// The open repo's relay channel, if it has one.
    public func liveUpdatesConfig() async -> RelayConfig? {
        guard let source, let text = try? await source.readText(RelayConfig.path) else { return nil }
        return try? JSONDecoder().decode(RelayConfig.self, from: Data(text.utf8))
    }

    /// Live updates need a push webhook on the provider, so they are for provider repos
    /// (GitHub, GitLab.com, self-hosted GitLab). Folders already update by themselves.
    public var canEnableLiveUpdates: Bool {
        guard let repo = activeRepo, !repo.kind.isFolder else { return false }
        return connection != nil
    }

    /// Register a channel on the relay, point a push webhook on the repo at it, and commit
    /// the channel into the repo so every device that reads the repo can subscribe.
    public func enableLiveUpdates() async {
        guard let repo = activeRepo, canEnableLiveUpdates else { return }
        if await enableLiveUpdates(on: repo) { startWatching() }
    }

    /// The same for any added provider repo, open or not: instant review notifications on a
    /// GitLab board use its channel. Returns whether the channel is on.
    @discardableResult
    func enableLiveUpdates(on repo: AddedRepo) async -> Bool {
        // The open repo writes through the source the board uses; any other through its own.
        let open = repo.id == activeRepo?.id ? self.source : nil
        guard !repo.kind.isFolder, let source = open ?? source(for: repo), let connection else { return false }
        guard let relay = URL(string: relayURL), relay.scheme?.hasPrefix("http") == true else {
            errorMessage = "Enter the relay's address first."
            return false
        }
        errorMessage = nil
        do {
            let registration = try await RelayClient.register(
                relay: relay, repo: repo.fullName, clientID: RelayClientProof.clientID(in: defaults))
            let hookID: Int
            do {
                hookID = try await ProviderWebhook.create(
                    with: connection, repo: repo.fullName, url: registration.hookURL, secret: registration.hookSecret)
            } catch {
                // No webhook, so no use for the channel: do not leave it behind on the relay.
                await RelayClient.remove(RelayConfig(relay: relayURL, channel: registration.channel,
                                                     subscribeKey: registration.subscribeKey, hookID: nil))
                throw error
            }
            let config = RelayConfig(relay: relayURL, channel: registration.channel,
                                     subscribeKey: registration.subscribeKey, hookID: hookID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let text = String(decoding: try encoder.encode(config), as: UTF8.self) + "\n"
            try await source.write(path: RelayConfig.path, text: text, message: "Turn on live updates")
            return true
        } catch {
            errorMessage = "Live updates were not turned on: \(error.localizedDescription)"
            return false
        }
    }

    /// Remove the webhook, the relay channel and the file in the repo.
    public func disableLiveUpdates() async {
        guard let repo = activeRepo, let source, let config = await liveUpdatesConfig() else { return }
        errorMessage = nil
        stopWatching()
        if let hookID = config.hookID, let connection {
            await ProviderWebhook.remove(hookID, with: connection, repo: repo.fullName)
        }
        await RelayClient.remove(config)
        do {
            try await source.delete(path: RelayConfig.path, message: "Turn off live updates")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
