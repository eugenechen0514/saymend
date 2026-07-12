import Foundation
import Security

/// 機密儲存介面：API key 只准放這裡（規格 §4.9）
public protocol SecretStore {
    func set(_ value: String, forKey key: String) throws
    func get(forKey key: String) throws -> String?
    func delete(forKey key: String) throws
}

public enum KeychainError: Error, Equatable {
    case status(OSStatus)
}

/// 真 Keychain 實作（generic password）。
/// M5 發佈時再以 kSecAttrAccessGroup 開跨程序共享（規格 §4.9 預留）。
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "io.speeckink.secrets") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(key) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        } else {
            guard update == errSecSuccess else { throw KeychainError.status(update) }
        }
    }

    public func get(forKey key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    public func delete(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// 測試與預覽用的記憶體實作
public final class InMemorySecretStore: SecretStore {
    private var storage: [String: String] = [:]
    public init() {}
    public func set(_ value: String, forKey key: String) throws { storage[key] = value }
    public func get(forKey key: String) throws -> String? { storage[key] }
    public func delete(forKey key: String) throws { storage[key] = nil }
}
