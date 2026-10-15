import Foundation
import Security
import Synchronization

protocol StudioOSCredentialStoring: Sendable {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

/// Test double and preview stand-in; never used for the real credential.
final class InMemoryCredentialStore: StudioOSCredentialStoring, @unchecked Sendable {
    private let token = Mutex<String?>(nil)
    func loadToken() throws -> String? { token.withLock { $0 } }
    func saveToken(_ newValue: String) throws { token.withLock { $0 = newValue } }
    func deleteToken() throws { token.withLock { $0 = nil } }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "The macOS Keychain refused the request (status \(status))."
    }
}

/// Stores the device token as a generic password in the user's login keychain.
struct KeychainCredentialStore: StudioOSCredentialStoring {
    var service = "com.perceptionmedia.editor.studio-os"
    var account = "device-token"

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func loadToken() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let updated = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
        var add = identity
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func deleteToken() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
