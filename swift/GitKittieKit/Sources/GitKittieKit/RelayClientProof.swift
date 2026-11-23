import CryptoKit
import Foundation

/// How a GitKittie client (Tasks, GitFolder, ...) shows the live-updates relay
/// (`apps/gitkanban-relay`) that it is one: each install has its own random id, and sends it
/// with a hash that ties the id, the time and the request to the client family.
public enum RelayClientProof {
    /// What every GitKittie client and the relay are built with (`CLIENT_FAMILY` in the
    /// relay's `src/signature.ts`; keep the two equal). It ships in the apps, so it is not a
    /// secret: it tells the family's clients from anything that merely found the relay.
    static let family = "gitkittie-client-v1:dcdbb50e99dd24b424c6ddea8c6eb7446dc199b802ff7346"

    /// The header the proof is sent in.
    public static let headerName = "X-GitKanban-Client"

    /// This install's random id, made on first use and kept in `defaults`.
    public static func clientID(in defaults: UserDefaults) -> String {
        let key = "gitkittie.relayClientID"
        if let existing = defaults.string(forKey: key), existing.count == 32 { return existing }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        let id = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(id, forKey: key)
        return id
    }

    /// `id=<id>,t=<unix seconds>,v1=<hex HMAC-SHA256 of "<id>.<t>.<body>" keyed with the family>`.
    public static func header(clientID: String, body: Data, time: Date = Date()) -> String {
        let seconds = Int(time.timeIntervalSince1970)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("\(clientID).\(seconds).".utf8) + body, using: SymmetricKey(data: Data(family.utf8)))
        return "id=\(clientID),t=\(seconds),v1=" + mac.map { String(format: "%02x", $0) }.joined()
    }
}
