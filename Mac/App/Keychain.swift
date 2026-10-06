// The device token lives in the keychain, scoped by canonical server origin; only the origin is saved in the defaults.
import Foundation
import Security

enum Keychain {
    /// The data protection keychain needs the keychain-access-groups entitlement, which only a build signed with the team's
    /// profile carries. The release build has none, so it keeps the token in the login keychain instead, where an item is
    /// readable without a prompt only by builds signed like the one that saved it: by the team's certificate, which
    /// each release is signed with, not ad hoc.
    private static let dataProtection: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
    }()

    /// The device token, one per server origin.
    static let device = "com.okanetsolutions.briareus.client"
    /// The meeting assistant's API keys, one per service ("elevenlabs").
    static let meeting = "com.okanetsolutions.briareus.meeting"

    private static func query(_ origin: String, _ service: String = device) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: origin,
         kSecAttrSynchronizable as String: false,
         // This Mac only: the data protection keychain, where device-only protection holds, not the login keychain.
         kSecUseDataProtectionKeychain as String: dataProtection]
    }
    static func read(_ origin: String, service: String = device) throws -> String? {
        var q = query(origin, service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw failure(status) }
        return token
    }
    /// The origins holding a token. Only the attributes are read, so a token outlives the defaults that name its origin.
    static func origins(service: String = device) -> [String] {
        var q = query("", service)
        q.removeValue(forKey: kSecAttrAccount as String)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
    static func save(_ token: String, origin: String, service: String = device) throws {
        let q = query(origin, service)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    @discardableResult
    static func remove(_ origin: String, service: String = device) -> Bool {
        let status = SecItemDelete(query(origin, service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    static let failureText = "Could not access the device token in the keychain. Unlock this Mac and try again."
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(failureText) (\(status))"])
    }
}
