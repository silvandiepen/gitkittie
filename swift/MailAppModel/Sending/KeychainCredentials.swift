import Foundation
import MailOutbox
import MailProvider
import Security

/// Reads an account's password from this app's Keychain at the moment the outbox connects.
/// Account setup (GKM-010) writes the item; this only reads it, and never keeps the value.
struct KeychainCredentials: CredentialProvider {
    struct Missing: Error, CustomStringConvertible {
        var status: OSStatus
        var description: String {
            status == errSecItemNotFound
                ? "No password is saved for this account on \(DeviceWords.this)."
                : "The Keychain refused to read the password (\(status))."
        }
    }

    func credential(for reference: CredentialReference) async throws -> MailCredential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Missing(status: status == errSecSuccess ? errSecDecode : status)
        }
        return .password(username: reference.username, password: Secret(value))
    }
}
