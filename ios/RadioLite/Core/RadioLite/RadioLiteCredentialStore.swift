import Foundation
import Security

enum RadioLiteCredentialStoreError: LocalizedError {
    case unexpectedData
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedData: "钥匙串中的登录信息格式无效"
        case .status(let status):
            (SecCopyErrorMessageString(status, nil) as String?) ?? "钥匙串操作失败（\(status)）"
        }
    }
}

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
        guard status == errSecSuccess else { throw RadioLiteCredentialStoreError.status(status) }
        guard let data = result as? Data else { throw RadioLiteCredentialStoreError.unexpectedData }
        do {
            return try JSONDecoder().decode(RadioLiteStoredLogin.self, from: data)
        } catch {
            throw RadioLiteCredentialStoreError.unexpectedData
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
        guard update == errSecItemNotFound else { throw RadioLiteCredentialStoreError.status(update) }
        var inserted = query
        attributes.forEach { inserted[$0.key] = $0.value }
        let status = SecItemAdd(inserted as CFDictionary, nil)
        guard status == errSecSuccess else { throw RadioLiteCredentialStoreError.status(status) }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RadioLiteCredentialStoreError.status(status)
        }
    }

    @discardableResult
    func delete(ifMatching expected: RadioLiteStoredLogin) throws -> Bool {
        guard try load() == expected else { return false }
        try delete()
        return true
    }
}
