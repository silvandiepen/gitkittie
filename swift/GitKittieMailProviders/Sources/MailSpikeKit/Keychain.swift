import Foundation
import MailProvider
import Security

/// Reads a password the person stored in their login Keychain. The spike never takes a
/// password from a file, an argument or an environment variable.
public enum KeychainPassword {
    public static func read(service: String, account: String) throws -> Secret {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw SpikeFailure("no Keychain item for service \"\(service)\", account \"\(account)\": \(message)")
        }
        return Secret(value)
    }
}
