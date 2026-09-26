import Foundation
import RelayProtocol
import Security

/// The tracker's token, in the login keychain.
///
/// Under the build's own identifier, so the development build keeps a token of
/// its own and signing out of one leaves the other signed in — the same line
/// every other piece of state is drawn along.
enum TrackerKeychain {
    static var service: String { RelayPaths.bundleIdentifier + ".tracker" }

    static func token(for address: String) -> String? {
        var query = baseQuery(for: address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// Replaces whatever was kept for the address.
    @discardableResult
    static func store(_ token: String, for address: String) -> Bool {
        remove(for: address)
        var item = baseQuery(for: address)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "Relay — \(address)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove(for address: String) {
        SecItemDelete(baseQuery(for: address) as CFDictionary)
    }

    private static func baseQuery(for address: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: address,
        ]
    }
}
