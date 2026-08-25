import Foundation
import Security

struct RadioLiteCredentialStore: Sendable {
    private let service = "xyz.992218.radio-lite.remote"
    private let account = "radio-lite-login-v1"

    func load() throws -> RadioLiteStoredLogin? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainTokenStoreError.status(status) }
        guard let data = result as? Data else { throw KeychainTokenStoreError.unexpectedData }
        do {
            return try JSONDecoder().decode(RadioLiteStoredLogin.self, from: data)
        } catch {
            throw KeychainTokenStoreError.unexpectedData
        }
    }

    func save(_ login: RadioLiteStoredLogin) throws {
        let data = try JSONEncoder().encode(login)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainTokenStoreError.status(update) }
        var inserted = query
        attributes.forEach { inserted[$0.key] = $0.value }
        let status = SecItemAdd(inserted as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainTokenStoreError.status(status) }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.status(status)
        }
    }
}
