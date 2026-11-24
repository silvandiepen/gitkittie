import Foundation
import MailCore
import MailProvider
import Security

/// Account passwords in the Keychain, and nowhere else (ThreatModel.md §5): never in
/// `account.json`, preferences, CloudKit, exports or logs. One item per account, keyed by the
/// account's local id; the value only leaves as a ``Secret``.
///
/// The app uses the data protection keychain with `…AfterFirstUnlockThisDeviceOnly`, so a
/// password never travels to another device or into a backup restore on another Mac: each
/// device signs in for itself (Architecture.md, Multi-device sync).
public struct KeychainCredentialStore: Sendable {
    public var service: String
    /// The data protection keychain (needs the app's keychain entitlement). `false` uses the
    /// file-based login keychain, which unsigned test runs can reach; the item is otherwise
    /// the same.
    public var useDataProtectionKeychain: Bool

    public init(service: String = "app.hakobs.gitmail.account", useDataProtectionKeychain: Bool = true) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    /// Stores (or replaces) the account's password.
    public func save(_ secret: Secret, for account: MailAccountID) throws {
        let data = secret.withValue { Data($0.utf8) }
        let query = baseQuery(account)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialStoreError(status: status, operation: "save") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "GitKittie Mail account password"
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw CredentialStoreError(status: added, operation: "save") }
    }

    /// The account's password, or nil when this device has none (a new device, or removed).
    public func secret(for account: MailAccountID) throws -> Secret? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status, operation: "read") }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError(status: errSecDecode, operation: "read")
        }
        return Secret(value)
    }

    /// Removes the account's password. Removing one that is not there is fine.
    public func delete(for account: MailAccountID) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(status: status, operation: "remove")
        }
    }

    private func baseQuery(_ account: MailAccountID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}

public struct CredentialStoreError: Error, Equatable, CustomStringConvertible {
    public var status: OSStatus
    public var operation: String

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "The Keychain couldn’t \(operation) the password: \(message)"
    }
}
